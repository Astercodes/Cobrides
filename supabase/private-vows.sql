-- Owner-only vow revisions. No collaborator access, notifications or public publishing.
begin;
create table if not exists public.cb_private_vows(user_id uuid not null references auth.users on delete cascade,scope text not null check(scope in ('personal','demo')),project_ref text not null,record_ref text not null,content text not null,revision bigint not null default 1,updated_at timestamptz not null default now(),primary key(user_id,scope,project_ref,record_ref));
create table if not exists public.cb_private_vow_history(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,record_ref text not null,revision bigint not null,content text not null,at timestamptz not null default now(),primary key(user_id,scope,project_ref,record_ref,revision));
create table if not exists public.cb_private_vow_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
alter table public.cb_private_vows enable row level security;alter table public.cb_private_vow_history enable row level security;alter table public.cb_private_vow_writes enable row level security;
revoke all on public.cb_private_vows,public.cb_private_vow_history,public.cb_private_vow_writes from public,anon,authenticated;
create or replace function public.cb_vow_source(p_scope text,p_project text,p_ref text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p jsonb;r jsonb;begin
 if auth.uid() is null or p_scope is null or p_scope not in ('personal','demo') or length(coalesce(p_ref,'')) not between 1 and 200 or length(coalesce(p_project,'')) not between 1 and 200 then raise exception 'Sign in to open your own vow draft' using errcode='42501';end if;
 select body->'value' into p from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_project and (body->'path'=jsonb_build_array(p_scope,'projects') or p_scope='personal' and body->'path'=jsonb_build_array('projects')) order by jsonb_array_length(body->'path') desc limit 1;
 select body->'value' into r from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_ref and (body->'path'=jsonb_build_array(p_scope,'faithRecords') or p_scope='personal' and body->'path'=jsonb_build_array('faithRecords')) order by jsonb_array_length(body->'path') desc limit 1;
 if p is null or r is null or r->>'projectId' is distinct from p_project or r->>'kind' is distinct from 'Ceremony & vows' or r->>'vowDraft' is distinct from 'true' or coalesce(r->>'archived','false')='true' or coalesce(p->>'archived','false')='true' or coalesce(p->>'archiveStatus','') like 'Archived%' then raise exception 'Open your own active vow draft first' using errcode='42501';end if;
 return r;end;$$;
create or replace function public.cb_open_private_vow(p_scope text,p_project text,p_ref text) returns jsonb language plpgsql security definer set search_path='' as $$
declare src jsonb;v public.cb_private_vows;begin
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':vow:'||p_scope||':'||p_project||':'||p_ref,0));perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 src=public.cb_vow_source(p_scope,p_project,p_ref);
 if length(coalesce(src->>'notes',''))>100000 then raise exception 'This draft exceeds 100,000 characters. Shorten it before opening.';end if;
 insert into public.cb_private_vows(user_id,scope,project_ref,record_ref,content) values(auth.uid(),p_scope,p_project,p_ref,coalesce(src->>'notes','')) on conflict do nothing;
 select * into v from public.cb_private_vows where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=p_ref;
 insert into public.cb_private_vow_history(user_id,scope,project_ref,record_ref,revision,content) values(v.user_id,v.scope,v.project_ref,v.record_ref,v.revision,v.content) on conflict do nothing;
 return jsonb_build_object('content',v.content,'revision',v.revision,'updated_at',v.updated_at);end;$$;
create or replace function public.cb_save_private_vow(p_scope text,p_project text,p_ref text,p_revision bigint,p_client uuid,p_content text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.cb_private_vows;payload jsonb;old public.cb_private_vow_writes;result jsonb;begin
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':vow:'||p_scope||':'||p_project||':'||p_ref,0));perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 perform public.cb_vow_source(p_scope,p_project,p_ref);
 if p_content is null or length(p_content)>100000 or p_client is null or p_revision is null then raise exception 'Use a valid draft of at most 100,000 characters';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'ref',p_ref,'revision',p_revision,'content',p_content);
 select * into old from public.cb_private_vow_writes where user_id=auth.uid() and client=p_client;
 if found then if old.payload<>payload then raise exception 'Retry the same vow update';end if;return old.response;end if;
 select * into v from public.cb_private_vows where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=p_ref for update;
 if not found then raise exception 'Open this vow draft before editing';end if;
 if v.revision<>p_revision then raise exception 'This draft changed on another device. Your words are still in the editor. Copy them before reopening the latest draft.' using errcode='PT409';end if;
 if v.content is distinct from p_content then update public.cb_private_vows set content=p_content,revision=revision+1,updated_at=now() where user_id=v.user_id and scope=v.scope and project_ref=v.project_ref and record_ref=v.record_ref returning * into v;
 insert into public.cb_private_vow_history(user_id,scope,project_ref,record_ref,revision,content) values(v.user_id,v.scope,v.project_ref,v.record_ref,v.revision,v.content);end if;
 result=jsonb_build_object('content',v.content,'revision',v.revision,'updated_at',v.updated_at);
 insert into public.cb_private_vow_writes values(auth.uid(),p_client,payload,result);return result;end;$$;
revoke all on function public.cb_vow_source(text,text,text),public.cb_open_private_vow(text,text,text),public.cb_save_private_vow(text,text,text,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.cb_open_private_vow(text,text,text),public.cb_save_private_vow(text,text,text,bigint,uuid,text) to authenticated;
commit;
