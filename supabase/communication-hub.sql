-- Shared conversations. Run after wedding-projects.sql, task-board.sql and file storage.
begin;
create table if not exists public.cb_chat_threads(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 title text not null check(length(trim(title)) between 1 and 120),created_by uuid not null references auth.users,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_chat_participants(
 thread_id uuid not null references public.cb_chat_threads on delete cascade,user_id uuid not null references auth.users,
 last_read_id bigint not null default 0,primary key(thread_id,user_id)
);
create table if not exists public.cb_chat_messages(
 id bigint generated always as identity primary key,thread_id uuid not null references public.cb_chat_threads on delete cascade,
 author_id uuid not null references auth.users,client_id uuid not null,body text not null check(length(body)<=3000),
 created_at timestamptz not null default now(),unique(thread_id,author_id,client_id)
);
create index if not exists cb_chat_message_history on public.cb_chat_messages(thread_id,id desc);
create table if not exists public.cb_chat_files(
 id uuid primary key default gen_random_uuid(),message_id bigint not null references public.cb_chat_messages on delete cascade,
 bucket text not null check(bucket='cb-documents'),path text not null,name text not null check(length(name) between 1 and 200),
 unique(message_id,bucket,path)
);
alter table public.cb_chat_threads enable row level security;
alter table public.cb_chat_participants enable row level security;
alter table public.cb_chat_messages enable row level security;
alter table public.cb_chat_files enable row level security;
revoke all on public.cb_chat_threads,public.cb_chat_participants,public.cb_chat_messages,public.cb_chat_files from public,anon,authenticated;
create or replace function public.cb_chat_access(p_thread uuid) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.cb_chat_threads t join public.cb_chat_participants x on x.thread_id=t.id
 where t.id=p_thread and x.user_id=auth.uid() and public.cb_project_access(t.project_id,'read'));
$$;
-- Directory is limited to accepted teammates; never exposes unrelated profiles or account emails.
create or replace function public.cb_chat_people(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Conversation access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(p.full_name,''),'Wedding team member'),'role',u.role) order by u.role,u.id),'[]')
 from (select owner_id id,'owner' role from public.cb_projects where id=p_project union select user_id,role from public.cb_members where project_id=p_project) u
 left join public.cb_profiles p on p.user_id=u.id);
end; $$;
create or replace function public.cb_create_chat(p_project uuid,p_title text,p_people uuid[]) returns uuid language plpgsql security definer set search_path='' as $$
declare tid uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'read') or exists(select 1 from public.cb_projects where id=p_project and archived_at is not null) then raise exception 'Conversation access denied' using errcode='42501';end if;
 if p_people is null or cardinality(p_people)<1 or cardinality(p_people)>50 or array_position(p_people,null) is not null or length(trim(coalesce(p_title,''))) not between 1 and 120 then raise exception 'Add a title and choose up to 50 accepted teammates';end if;
 if exists(select 1 from unnest(p_people) person where not exists(select 1 from public.cb_projects where id=p_project and owner_id=person) and not exists(select 1 from public.cb_members where project_id=p_project and user_id=person)) then raise exception 'Choose accepted wedding teammates only';end if;
 if (select count(*) from public.cb_chat_threads where created_by=auth.uid() and created_at>now()-interval '1 day')>=20 then raise exception 'Conversation creation limit reached. Continue in an existing conversation.';end if;
 insert into public.cb_chat_threads(project_id,title,created_by) values(p_project,trim(p_title),auth.uid()) returning id into tid;
 insert into public.cb_chat_participants(thread_id,user_id) select tid,id from (select distinct unnest(p_people||array[auth.uid()]) id) people;
 return tid;
end; $$;
create or replace function public.cb_list_chats(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Conversation access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(row order by updated_at desc),'[]') from (
 select t.updated_at,jsonb_build_object('id',t.id,'title',t.title,'created_by',t.created_by,'updated_at',t.updated_at,
 'unread',(select count(*) from public.cb_chat_messages m where m.thread_id=t.id and m.id>x.last_read_id and m.author_id<>auth.uid()),
 'preview',(select left(body,100) from public.cb_chat_messages where thread_id=t.id order by id desc limit 1)) row
 from public.cb_chat_threads t join public.cb_chat_participants x on x.thread_id=t.id and x.user_id=auth.uid() where t.project_id=p_project order by t.updated_at desc limit 200) records);
end; $$;
create or replace function public.cb_chat_history(p_thread uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare messages jsonb;people jsonb;
begin
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;
 select coalesce(jsonb_agg(row order by id),'[]') into messages from (
 select m.id,jsonb_build_object('id',m.id::text,'author_id',m.author_id,'body',m.body,'client_id',m.client_id,'at',m.created_at,
 'read_by',(select count(*) from public.cb_chat_participants x where x.thread_id=m.thread_id and x.user_id<>m.author_id and x.last_read_id>=m.id
 and (exists(select 1 from public.cb_projects p join public.cb_chat_threads t on t.project_id=p.id where t.id=m.thread_id and p.owner_id=x.user_id)
 or exists(select 1 from public.cb_members mem join public.cb_chat_threads t on t.project_id=mem.project_id where t.id=m.thread_id and mem.user_id=x.user_id))),
 'files',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name)),'[]') from public.cb_chat_files where message_id=m.id)) row
 from public.cb_chat_messages m where m.thread_id=p_thread and (p_before is null or m.id<p_before) order by m.id desc limit 50) batch;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.user_id,'name',coalesce(nullif(p.full_name,''),'Wedding team member'))),'[]') into people
 from public.cb_chat_participants x left join public.cb_profiles p on p.user_id=x.user_id where x.thread_id=p_thread;
 return jsonb_build_object('messages',messages,'people',people);
end; $$;
create or replace function public.cb_send_chat_message(p_thread uuid,p_client uuid,p_body text,p_files jsonb default '[]') returns text
language plpgsql security definer set search_path='' as $$
declare mid bigint;file jsonb;pid uuid;existing public.cb_chat_messages;
begin
 select project_id into pid from public.cb_chat_threads where id=p_thread;
 perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_chat_access(p_thread) or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Conversation access denied' using errcode='42501';end if;
 if p_client is null or p_body is null or length(p_body)>3000 or jsonb_typeof(p_files) is distinct from 'array' or jsonb_array_length(p_files)>3 or (length(trim(p_body))=0 and jsonb_array_length(p_files)=0) then raise exception 'Add a message or up to three files';end if;
 select * into existing from public.cb_chat_messages where thread_id=p_thread and author_id=auth.uid() and client_id=p_client;
 if found then
  if existing.body<>p_body then raise exception 'Message changed during retry. Refresh before sending.';end if;
  return existing.id::text;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('cb-chat-send:'||auth.uid()::text,0));
 if (select count(*) from public.cb_chat_messages where author_id=auth.uid() and created_at>now()-interval '1 minute')>=30 then raise exception 'Please wait a moment before sending more messages';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 for file in select value from jsonb_array_elements(p_files) loop
  if file->>'bucket' is distinct from 'cb-documents' or split_part(file->>'path','/',1) is distinct from auth.uid()::text
  or length(coalesce(file->>'name','')) not between 1 and 200 or not exists(select 1 from storage.objects where bucket_id='cb-documents' and name=file->>'path')
  or exists(select 1 from public.cb_file_reservations where bucket='cb-documents' and path=file->>'path' and deleting) then raise exception 'Upload your own file before sharing it';end if;
 end loop;
 insert into public.cb_chat_messages(thread_id,author_id,client_id,body) values(p_thread,auth.uid(),p_client,p_body) returning id into mid;
 for file in select value from jsonb_array_elements(p_files) loop
  insert into public.cb_chat_files(message_id,bucket,path,name) values(mid,'cb-documents',file->>'path',file->>'name') on conflict do nothing;
 end loop;
 update public.cb_chat_threads set updated_at=now() where id=p_thread;
 return mid::text;
end; $$;
create or replace function public.cb_mark_chat_read(p_thread uuid,p_through bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;
 update public.cb_chat_participants set last_read_id=greatest(last_read_id,least(coalesce(p_through,0),coalesce((select max(id) from public.cb_chat_messages where thread_id=p_thread),0))) where thread_id=p_thread and user_id=auth.uid();
end; $$;
create or replace function public.cb_chat_file_access(p_bucket text,p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_chat_files f join public.cb_chat_messages m on m.id=f.message_id where f.bucket=p_bucket and f.path=p_path and public.cb_chat_access(m.thread_id));
$$;
create or replace function public.cb_chat_file(p_file uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare file public.cb_chat_files;
begin
 select * into file from public.cb_chat_files where id=p_file;
 if not found or not public.cb_chat_file_access(file.bucket,file.path) then raise exception 'Attachment access denied' using errcode='42501';end if;
 return jsonb_build_object('bucket',file.bucket,'path',file.path,'name',file.name);
end; $$;
drop policy if exists cb_shared_chat_file_read on storage.objects;
create policy cb_shared_chat_file_read on storage.objects for select to authenticated using(public.cb_chat_file_access(bucket_id,name));
do $$begin
 if to_regprocedure('public.cb_file_referenced_before_chat(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_chat;end if;
end$$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$
 select public.cb_file_referenced_before_chat(p_bucket,p_path) or exists(select 1 from public.cb_chat_files where bucket=p_bucket and path=p_path);
$$;
revoke all on function public.cb_chat_access(uuid),public.cb_chat_people(uuid),public.cb_create_chat(uuid,text,uuid[]),public.cb_list_chats(uuid),public.cb_chat_history(uuid,bigint),public.cb_send_chat_message(uuid,uuid,text,jsonb),public.cb_mark_chat_read(uuid,bigint),public.cb_chat_file_access(text,text),public.cb_chat_file(uuid),public.cb_file_referenced(text,text) from public,anon,authenticated;
grant execute on function public.cb_chat_access(uuid),public.cb_chat_people(uuid),public.cb_create_chat(uuid,text,uuid[]),public.cb_list_chats(uuid),public.cb_chat_history(uuid,bigint),public.cb_send_chat_message(uuid,uuid,text,jsonb),public.cb_mark_chat_read(uuid,bigint),public.cb_chat_file_access(text,text),public.cb_chat_file(uuid),public.cb_file_referenced(text,text) to authenticated;
notify pgrst,'reload schema';
commit;
