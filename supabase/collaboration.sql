-- Run once in the Supabase SQL editor. No service-role key is needed by CoBrides.
create table public.cb_projects(id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users, title text not null check(length(title) between 1 and 200), created_at timestamptz default now());
create table public.cb_members(project_id uuid references public.cb_projects on delete cascade, user_id uuid references auth.users on delete cascade, role text not null check(role in ('planner','partner','family','bridal-party','vendor','guest')), primary key(project_id,user_id));
create table public.cb_invites(id uuid primary key default gen_random_uuid(), project_id uuid not null references public.cb_projects on delete cascade, email text not null, role text not null check(role in ('planner','partner','family','bridal-party','vendor','guest')), token uuid unique not null default gen_random_uuid(), expires_at timestamptz not null default now()+interval '7 days', accepted_at timestamptz, revoked boolean default false);
create table public.cb_tasks(id uuid primary key default gen_random_uuid(), project_id uuid not null references public.cb_projects on delete cascade, title text not null check(length(title) between 1 and 300), assignee_email text not null, due_date date, done boolean not null default false, updated_at timestamptz default now());
create table public.cb_messages(id uuid primary key default gen_random_uuid(), project_id uuid not null references public.cb_projects on delete cascade, author_id uuid not null references auth.users, body text not null check(length(body) between 1 and 3000), created_at timestamptz default now());
create function public.cb_manager(pid uuid) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.cb_projects where id=pid and owner_id=auth.uid()) or exists(select 1 from public.cb_members where project_id=pid and user_id=auth.uid() and role='planner'); $$;
create function public.cb_member(pid uuid) returns boolean language sql stable security definer set search_path='' as $$ select public.cb_manager(pid) or exists(select 1 from public.cb_members where project_id=pid and user_id=auth.uid()); $$;
alter table public.cb_projects enable row level security;
alter table public.cb_members enable row level security;
alter table public.cb_invites enable row level security;
alter table public.cb_tasks enable row level security;
alter table public.cb_messages enable row level security;
create policy projects_read on public.cb_projects for select to authenticated using(public.cb_member(id));
create policy projects_create on public.cb_projects for insert to authenticated with check(owner_id=auth.uid());
create policy members_read on public.cb_members for select to authenticated using(user_id=auth.uid() or public.cb_manager(project_id));
create policy invites_read on public.cb_invites for select to authenticated using(public.cb_manager(project_id));
create policy invites_create on public.cb_invites for insert to authenticated with check(public.cb_manager(project_id) and (role<>'planner' or exists(select 1 from public.cb_projects where id=project_id and owner_id=auth.uid())));
-- No direct updates to roles, invitation tokens or task assignments by collaborators.
create policy tasks_read on public.cb_tasks for select to authenticated using(public.cb_manager(project_id) or (public.cb_member(project_id) and lower(assignee_email)=lower(coalesce(auth.jwt()->>'email',''))));
create policy tasks_create on public.cb_tasks for insert to authenticated with check(public.cb_manager(project_id));
create policy messages_read on public.cb_messages for select to authenticated using(public.cb_member(project_id));
create policy messages_create on public.cb_messages for insert to authenticated with check(public.cb_member(project_id) and author_id=auth.uid());
create function public.cb_accept_invite(invite_token uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare invitation public.cb_invites;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into invitation from public.cb_invites where token=invite_token for update;
 if not found or invitation.revoked or invitation.expires_at<now() or invitation.accepted_at is not null then raise exception 'Invitation is expired, revoked or already accepted'; end if;
 if lower(invitation.email)<>lower(coalesce(auth.jwt()->>'email','')) then raise exception 'Sign in with the invited email address'; end if;
 if exists(select 1 from public.cb_projects where id=invitation.project_id and owner_id=auth.uid()) then raise exception 'You already own this project'; end if;
 insert into public.cb_members(project_id,user_id,role) values(invitation.project_id,auth.uid(),invitation.role) on conflict do nothing;
 update public.cb_invites set accepted_at=now() where id=invitation.id;
 return invitation.project_id;
end; $$;
create function public.cb_complete_task(task_id uuid, completed boolean) returns void language plpgsql security definer set search_path='' as $$
declare task public.cb_tasks;
begin
 select * into task from public.cb_tasks where id=task_id for update;
 if not found or not (public.cb_manager(task.project_id) or (public.cb_member(task.project_id) and lower(task.assignee_email)=lower(coalesce(auth.jwt()->>'email','')))) then raise exception 'Task access denied'; end if;
 update public.cb_tasks set done=completed,updated_at=now() where id=task_id;
end; $$;
create function public.cb_revoke_invite(invite_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.cb_invites set revoked=true where id=invite_id and public.cb_manager(project_id) and accepted_at is null;
 if not found then raise exception 'Invitation cannot be revoked'; end if;
end; $$;
create function public.cb_remove_member(pid uuid, member_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.cb_projects where id=pid and owner_id=auth.uid()) then raise exception 'Only the project owner can remove access'; end if;
 delete from public.cb_members where project_id=pid and user_id=member_id;
end; $$;
revoke all on public.cb_projects,public.cb_members,public.cb_invites,public.cb_tasks,public.cb_messages from anon,authenticated;
grant select,insert on public.cb_projects,public.cb_invites,public.cb_tasks,public.cb_messages to authenticated;
grant select on public.cb_members to authenticated;
revoke all on function public.cb_manager(uuid),public.cb_member(uuid),public.cb_accept_invite(uuid),public.cb_complete_task(uuid,boolean),public.cb_revoke_invite(uuid),public.cb_remove_member(uuid,uuid) from public,anon;
grant execute on function public.cb_manager(uuid),public.cb_member(uuid),public.cb_accept_invite(uuid),public.cb_complete_task(uuid,boolean),public.cb_revoke_invite(uuid),public.cb_remove_member(uuid,uuid) to authenticated;
