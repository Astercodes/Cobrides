-- CoBrides shared wedding projects. Run after collaboration.sql and accounts.sql.
-- Existing personal workspaces and collaboration projects are preserved.
begin;
alter table public.cb_projects add column if not exists details jsonb not null default '{}',
 add column if not exists revision bigint not null default 1,
 add column if not exists updated_at timestamptz not null default now(),
 add column if not exists archived_at timestamptz;
alter table public.cb_members add column if not exists financial_access boolean not null default false;
create table if not exists public.cb_project_links (
 user_id uuid not null references auth.users on delete cascade, local_ref text not null,
 project_id uuid not null references public.cb_projects on delete cascade,
 primary key(user_id,local_ref),unique(user_id,project_id)
);
create table if not exists public.cb_project_finances (
 project_id uuid primary key references public.cb_projects on delete cascade,
 budget numeric not null default 0 check(budget>=0), currency text not null default 'USD' check(currency ~ '^[A-Z]{3}$')
);
create table if not exists public.cb_project_events (
 id uuid primary key default gen_random_uuid(), project_id uuid not null references public.cb_projects on delete cascade,
 local_ref text not null, title text not null check(length(title) between 1 and 200),
 details jsonb not null default '{}', revision bigint not null default 1,
 visibility text not null default 'team' check(visibility in ('team','restricted')),
 updated_at timestamptz not null default now(),unique(project_id,local_ref)
);
create table if not exists public.cb_project_event_members (
 event_id uuid not null references public.cb_project_events on delete cascade,
 user_id uuid not null references auth.users on delete cascade,primary key(event_id,user_id)
);
create table if not exists public.cb_project_activity (
 id bigint generated always as identity primary key,project_id uuid not null references public.cb_projects on delete cascade,
 actor_id uuid references auth.users on delete set null,action text not null,changed_fields text[] not null default '{}',
 created_at timestamptz not null default now()
);
create index if not exists cb_project_activity_recent on public.cb_project_activity(project_id,id desc);
create or replace function public.cb_project_access(pid uuid,permission text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_projects p left join public.cb_members m on m.project_id=p.id and m.user_id=auth.uid()
 where p.id=pid and auth.uid() is not null and (p.owner_id=auth.uid() or m.user_id is not null) and
 case permission
 when 'read' then true
 when 'owner' then p.owner_id=auth.uid()
 when 'write' then p.archived_at is null and (p.owner_id=auth.uid() or m.role in ('bride','planner','partner'))
 when 'invite' then p.archived_at is null and (p.owner_id=auth.uid() or m.role in ('bride','planner'))
 when 'finance' then p.owner_id=auth.uid() or m.role='bride' or m.financial_access
 else false end);
$$;
create or replace function public.cb_project_event_access(eid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_project_events e where e.id=eid and public.cb_project_access(e.project_id,'read') and
 (public.cb_project_access(e.project_id,'write') or (e.visibility='team' and exists(select 1 from public.cb_members m where m.project_id=e.project_id and m.user_id=auth.uid() and m.role in ('family','bridal-party')))
 or exists(select 1 from public.cb_project_event_members where event_id=e.id and user_id=auth.uid())));
$$;
alter table public.cb_project_links enable row level security;
alter table public.cb_project_finances enable row level security;
alter table public.cb_project_events enable row level security;
alter table public.cb_project_event_members enable row level security;
alter table public.cb_project_activity enable row level security;
revoke all on public.cb_project_links,public.cb_project_finances,public.cb_project_events,public.cb_project_event_members,public.cb_project_activity from public,anon,authenticated;
grant select on public.cb_project_links,public.cb_project_finances,public.cb_project_events,public.cb_project_event_members,public.cb_project_activity to authenticated;
drop policy if exists project_links_owner on public.cb_project_links;
create policy project_links_owner on public.cb_project_links for select to authenticated using(user_id=auth.uid());
drop policy if exists project_finance_read on public.cb_project_finances;
create policy project_finance_read on public.cb_project_finances for select to authenticated using(public.cb_project_access(project_id,'finance'));
drop policy if exists project_events_read on public.cb_project_events;
create policy project_events_read on public.cb_project_events for select to authenticated using(public.cb_project_event_access(id));
drop policy if exists project_event_members_read on public.cb_project_event_members;
create policy project_event_members_read on public.cb_project_event_members for select to authenticated using(user_id=auth.uid() or exists(select 1 from public.cb_project_events e where e.id=event_id and public.cb_project_access(e.project_id,'invite')));
drop policy if exists project_activity_read on public.cb_project_activity;
create policy project_activity_read on public.cb_project_activity for select to authenticated using(public.cb_project_access(project_id,'read'));

create or replace function public.cb_project_details(p_details jsonb) returns jsonb language plpgsql set search_path='' as $$
declare result jsonb; value text;
begin
 if jsonb_typeof(p_details)<>'object' or octet_length(p_details::text)>20000 then raise exception 'Invalid project details'; end if;
 select coalesce(jsonb_object_agg(key,val),'{}') into result from jsonb_each(p_details) x(key,val)
 where key in ('date','dateStatus','location','anniversary','candidateDates','phases');
 for value in select result->>'date' union all select result->>'anniversary' loop
  if coalesce(value,'')<>'' then if value !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Use a valid date'; end if;perform value::date;end if;
 end loop;
 if result->>'dateStatus'='Confirmed' and coalesce(result->>'date','')='' then raise exception 'Add a date before confirming it';end if;
 if result ? 'dateStatus' and result->>'dateStatus' not in ('Projected','Tentative','Confirmed') then raise exception 'Choose a valid date status';end if;
 if result ? 'phases' and jsonb_typeof(result->'phases')<>'array' then raise exception 'Planning phases must be a list';end if;
 if result ? 'candidateDates' then
  if jsonb_typeof(result->'candidateDates')<>'array' then raise exception 'Candidate dates must be a list';end if;
  for value in select jsonb_array_elements_text(result->'candidateDates') loop if value !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Use valid candidate dates';end if;perform value::date;end loop;
 end if;
 if length(coalesce(result->>'location',''))>300 then raise exception 'Location is too long';end if;
 return result;
end; $$;
create or replace function public.cb_create_wedding_project(p_local_ref text,p_title text,p_details jsonb,p_budget numeric default 0,p_currency text default 'USD')
returns public.cb_projects language plpgsql security definer set search_path='' as $$
declare project public.cb_projects; safe jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 if length(trim(p_title)) not between 1 and 200 or length(p_local_ref) not between 1 and 300 or p_budget<0 then raise exception 'Enter valid project details';end if;
 safe:=public.cb_project_details(p_details);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':project:'||p_local_ref,0));
 select p.* into project from public.cb_project_links l join public.cb_projects p on p.id=l.project_id where l.user_id=auth.uid() and l.local_ref=p_local_ref;
 if found then return project;end if;
 insert into public.cb_projects(owner_id,title,details) values(auth.uid(),trim(p_title),safe) returning * into project;
 insert into public.cb_project_links values(auth.uid(),p_local_ref,project.id);
 insert into public.cb_project_finances(project_id,budget,currency) values(project.id,p_budget,p_currency);
 insert into public.cb_project_activity(project_id,actor_id,action) values(project.id,auth.uid(),'Project created');
 return project;
end; $$;
create or replace function public.cb_update_wedding_project(p_project uuid,p_revision bigint,p_title text,p_details jsonb,p_budget numeric default null,p_currency text default null)
returns public.cb_projects language plpgsql security definer set search_path='' as $$
declare project public.cb_projects; safe jsonb;
begin
 select * into project from public.cb_projects where id=p_project for update;
 if not found or not public.cb_project_access(p_project,'write') then raise exception 'Project edit access denied';end if;
 if project.revision<>p_revision then raise exception 'CB_PROJECT_CONFLICT: Another team member saved changes. Refresh before saving.' using errcode='PT409';end if;
 if length(trim(p_title)) not between 1 and 200 then raise exception 'Enter a project name';end if;
 safe:=public.cb_project_details(p_details);
 if p_budget is not null or p_currency is not null then
  if not public.cb_project_access(p_project,'finance') then raise exception 'Financial access denied';end if;
  insert into public.cb_project_finances(project_id,budget,currency) values(p_project,coalesce(p_budget,0),coalesce(p_currency,'USD'))
  on conflict(project_id) do update set budget=coalesce(p_budget,cb_project_finances.budget),currency=coalesce(p_currency,cb_project_finances.currency);
 end if;
 update public.cb_projects set title=trim(p_title),details=safe,revision=revision+1,updated_at=now() where id=p_project returning * into project;
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Project updated',array['Project details']);
 return project;
end; $$;
create or replace function public.cb_set_project_archived(p_project uuid,p_revision bigint,p_archived boolean) returns public.cb_projects
language plpgsql security definer set search_path='' as $$
declare project public.cb_projects;
begin
 select * into project from public.cb_projects where id=p_project for update;
 if not found or not public.cb_project_access(p_project,'owner') then raise exception 'Only the owner can archive or restore this project';end if;
 if project.revision<>p_revision then raise exception 'CB_PROJECT_CONFLICT: Refresh before changing the project.' using errcode='PT409';end if;
 update public.cb_projects set archived_at=case when p_archived then now() else null end,revision=revision+1,updated_at=now() where id=p_project returning * into project;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),case when p_archived then 'Project archived' else 'Project restored' end);
 return project;
end; $$;
create or replace function public.cb_set_project_member(p_project uuid,p_user uuid,p_role text,p_financial_access boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'owner') then raise exception 'Only the owner can change team permissions';end if;
 if p_role not in ('bride','planner','partner','family','bridal-party','vendor','guest') then raise exception 'Choose an available role';end if;
 update public.cb_members set role=p_role,financial_access=p_financial_access where project_id=p_project and user_id=p_user;
 if not found then raise exception 'Team member not found';end if;
 update public.cb_projects set revision=revision+1,updated_at=now() where id=p_project;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Team permissions updated');
end; $$;

create or replace function public.cb_save_project_event(p_project uuid,p_local_ref text,p_revision bigint,p_title text,p_details jsonb,p_visibility text default 'team')
returns public.cb_project_events language plpgsql security definer set search_path='' as $$
declare event public.cb_project_events; safe jsonb; date_value text;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Celebration edit access denied';end if;
 if length(trim(p_title)) not between 1 and 200 or length(p_local_ref) not between 1 and 300 or p_visibility not in ('team','restricted') or jsonb_typeof(p_details)<>'object' or octet_length(p_details::text)>20000 then raise exception 'Enter valid celebration details';end if;
 select coalesce(jsonb_object_agg(key,val),'{}') into safe from jsonb_each(p_details) x(key,val) where key in ('type','date','dateStatus','time','endTime','venue','dressCode','owner','logistics');
 date_value:=safe->>'date';if coalesce(date_value,'')<>'' then if date_value !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Use a valid celebration date';end if;perform date_value::date;end if;
 select * into event from public.cb_project_events where project_id=p_project and local_ref=p_local_ref for update;
 if coalesce(event.revision,0)<>p_revision then raise exception 'CB_PROJECT_CONFLICT: Refresh this celebration before saving.' using errcode='PT409';end if;
 if event.id is null then insert into public.cb_project_events(project_id,local_ref,title,details,visibility) values(p_project,p_local_ref,trim(p_title),safe,p_visibility) returning * into event;
 else update public.cb_project_events set title=trim(p_title),details=safe,visibility=p_visibility,revision=revision+1,updated_at=now() where id=event.id returning * into event;end if;
 update public.cb_projects set revision=revision+1,updated_at=now() where id=p_project;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Celebration updated');
 return event;
end; $$;
create or replace function public.cb_set_event_member(p_event uuid,p_user uuid,p_allowed boolean) returns void
language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 select project_id into pid from public.cb_project_events where id=p_event;
 if pid is null or not public.cb_project_access(pid,'invite') then raise exception 'Celebration access management denied';end if;
 if not exists(select 1 from public.cb_members where project_id=pid and user_id=p_user) then raise exception 'Invite this person to the project first';end if;
 if p_allowed then insert into public.cb_project_event_members values(p_event,p_user) on conflict do nothing;
 else delete from public.cb_project_event_members where event_id=p_event and user_id=p_user;end if;
 insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),'Celebration access updated');
end; $$;

-- Existing collaboration workspaces use the same project membership decisions.
create or replace function public.cb_manager(pid uuid) returns boolean language sql stable security definer set search_path='' as $$ select public.cb_project_access(pid,'invite'); $$;
create or replace function public.cb_member(pid uuid) returns boolean language sql stable security definer set search_path='' as $$ select public.cb_project_access(pid,'read'); $$;
create or replace function public.cb_remove_member(pid uuid,member_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_project_access(pid,'owner') then raise exception 'Only the project owner can remove access';end if;
 delete from public.cb_members where project_id=pid and user_id=member_id;
 delete from public.cb_project_event_members where user_id=member_id and event_id in(select id from public.cb_project_events where project_id=pid);
 update public.cb_projects set revision=revision+1,updated_at=now() where id=pid;
 insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),'Team access removed');
end; $$;
create or replace function public.cb_project_membership_log() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.cb_project_activity(project_id,actor_id,action) values(new.project_id,auth.uid(),'Team member joined');
 update public.cb_projects set revision=revision+1,updated_at=now() where id=new.project_id;
 return new;
end; $$;
drop trigger if exists cb_project_member_joined on public.cb_members;
create trigger cb_project_member_joined after insert on public.cb_members for each row execute function public.cb_project_membership_log();
create or replace function public.cb_project_team(p_project uuid)
returns table(user_id uuid,role text,financial_access boolean,display_name text,email text)
language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'invite') then raise exception 'Team directory access denied';end if;
 return query select m.user_id,m.role,m.financial_access,coalesce(p.full_name,'Team member'),u.email::text
 from public.cb_members m join auth.users u on u.id=m.user_id left join public.cb_profiles p on p.user_id=m.user_id where m.project_id=p_project;
end; $$;
create or replace function public.cb_accept_invite(invite_token uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare invitation public.cb_invites; project public.cb_projects;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into invitation from public.cb_invites where token=invite_token for update;
 if not found or invitation.revoked or invitation.expires_at<now() or invitation.accepted_at is not null then raise exception 'Invitation is expired, revoked or already accepted';end if;
 if lower(invitation.email)<>lower(coalesce(auth.jwt()->>'email','')) then raise exception 'Sign in with the invited email address';end if;
 select * into project from public.cb_projects where id=invitation.project_id for update;
 if project.archived_at is not null then raise exception 'This wedding project is archived';end if;
 if project.owner_id=auth.uid() then raise exception 'You already own this project';end if;
 if invitation.transfer_ownership then
  if invitation.role<>'bride' or invitation.created_by is distinct from project.owner_id or not exists(select 1 from public.cb_profiles where user_id=project.owner_id and account_type='planner') then raise exception 'The project owner changed. Request a new bride invitation';end if;
  insert into public.cb_members(project_id,user_id,role) values(project.id,project.owner_id,'planner') on conflict(project_id,user_id) do update set role='planner';
  update public.cb_projects set owner_id=auth.uid(),revision=revision+1,updated_at=now() where id=project.id;
  insert into public.cb_project_activity(project_id,actor_id,action) values(project.id,auth.uid(),'Ownership transferred to bride');
 end if;
 insert into public.cb_members(project_id,user_id,role) values(project.id,auth.uid(),invitation.role) on conflict do nothing;
 update public.cb_invites set accepted_at=now() where id=invitation.id;
 return project.id;
end; $$;
revoke all on function public.cb_project_membership_log(),public.cb_project_details(jsonb) from public,anon,authenticated;
revoke all on function public.cb_project_team(uuid) from public,anon;
grant execute on function public.cb_project_team(uuid) to authenticated;
revoke all on function public.cb_project_access(uuid,text),public.cb_project_event_access(uuid),public.cb_create_wedding_project(text,text,jsonb,numeric,text),public.cb_update_wedding_project(uuid,bigint,text,jsonb,numeric,text),public.cb_set_project_archived(uuid,bigint,boolean),public.cb_set_project_member(uuid,uuid,text,boolean),public.cb_save_project_event(uuid,text,bigint,text,jsonb,text),public.cb_set_event_member(uuid,uuid,boolean) from public,anon;
grant execute on function public.cb_project_access(uuid,text),public.cb_project_event_access(uuid),public.cb_create_wedding_project(text,text,jsonb,numeric,text),public.cb_update_wedding_project(uuid,bigint,text,jsonb,numeric,text),public.cb_set_project_archived(uuid,bigint,boolean),public.cb_set_project_member(uuid,uuid,text,boolean),public.cb_save_project_event(uuid,text,bigint,text,jsonb,text),public.cb_set_event_member(uuid,uuid,boolean) to authenticated;
commit;
