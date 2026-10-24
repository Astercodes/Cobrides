-- Cobridey: shared stakeholder directory and owner-controlled custom access.
-- Run after wedding-projects.sql, shared-planning.sql and team-invitation-roles.sql.
begin;
create table if not exists public.cb_collab_roles(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 title text not null check(length(btrim(title)) between 1 and 100),grants text[] not null default '{}',
 revision bigint not null default 1,updated_at timestamptz not null default now(),unique(project_id,id),
 check(grants <@ array['planning.write','events.read','finance.read','team.invite']::text[])
);
create table if not exists public.cb_collab_access(
 project_id uuid not null,user_id uuid not null,role_id uuid,expires_at timestamptz,revision bigint not null default 1,
 primary key(project_id,user_id),foreign key(project_id,user_id) references public.cb_members(project_id,user_id) on delete cascade,
 foreign key(project_id,role_id) references public.cb_collab_roles(project_id,id)
);
create table if not exists public.cb_stakeholders(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 local_ref text not null,title text not null check(length(btrim(title)) between 1 and 120),
 email text not null default '',phone text not null default '',relationship text not null default '',responsibilities text not null default '',
 revision bigint not null default 1,updated_at timestamptz not null default now(),unique(project_id,local_ref),
 check(length(email)<=254 and length(phone)<=100 and length(relationship)<=160 and length(responsibilities)<=3000)
);
create unique index if not exists cb_stakeholder_email on public.cb_stakeholders(project_id,lower(email)) where email<>'';
alter table public.cb_collab_roles enable row level security;
alter table public.cb_collab_access enable row level security;
alter table public.cb_stakeholders enable row level security;
revoke all on public.cb_collab_roles,public.cb_collab_access,public.cb_stakeholders from public,anon,authenticated;
grant select on public.cb_collab_roles,public.cb_collab_access to authenticated;
create or replace function public.cb_collab_user_access(p_user uuid,pid uuid,permission text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_projects p
 left join public.cb_members m on m.project_id=p.id and m.user_id=p_user
 left join public.cb_collab_access a on a.project_id=p.id and a.user_id=m.user_id
 left join public.cb_collab_roles r on r.project_id=a.project_id and r.id=a.role_id
 where p.id=pid and p_user is not null and (p.owner_id=p_user or (m.user_id is not null and (a.expires_at is null or a.expires_at>now()))) and
 case permission
 when 'read' then true
 when 'owner' then p.owner_id=p_user
 when 'write' then p.archived_at is null and (p.owner_id=p_user or case when r.id is not null then m.role in ('bride','planner','partner') and 'planning.write'=any(r.grants) else m.role in ('bride','planner','partner') end)
 when 'invite' then p.archived_at is null and (p.owner_id=p_user or case when r.id is not null then m.role in ('bride','planner') and 'team.invite'=any(r.grants) else m.role in ('bride','planner') end)
 when 'finance' then p.owner_id=p_user or case when r.id is not null then (m.role='bride' or m.financial_access) and 'finance.read'=any(r.grants) else m.role='bride' or m.financial_access end
 when 'events' then p.owner_id=p_user or r.id is null or 'events.read'=any(r.grants)
 else false end);
$$;
revoke all on function public.cb_collab_user_access(uuid,uuid,text) from public,anon,authenticated;
create or replace function public.cb_project_access(pid uuid,permission text) returns boolean language sql stable security definer set search_path='' as $$select public.cb_collab_user_access(auth.uid(),pid,permission)$$;
create or replace function public.cb_member(pid uuid) returns boolean language sql stable security definer set search_path='' as $$select public.cb_project_access(pid,'read')$$;
create or replace function public.cb_manager(pid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_project_access(pid,'write') and (exists(select 1 from public.cb_projects where id=pid and owner_id=auth.uid()) or exists(select 1 from public.cb_members where project_id=pid and user_id=auth.uid() and role in ('bride','planner')));
$$;
create or replace function public.cb_task_manager(pid uuid) returns boolean language sql stable security definer set search_path='' as $$select public.cb_project_access(pid,'write')$$;
create or replace function public.cb_project_event_access(eid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_project_events e where e.id=eid and public.cb_project_access(e.project_id,'read') and public.cb_project_access(e.project_id,'events') and
 (public.cb_project_access(e.project_id,'write') or (e.visibility='team' and exists(select 1 from public.cb_members m where m.project_id=e.project_id and m.user_id=auth.uid() and m.role in ('family','sibling','friend','bridal-party'))) or exists(select 1 from public.cb_project_event_members where event_id=e.id and user_id=auth.uid())));
$$;
create or replace function public.cb_revoke_invite(invite_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.cb_invites set revoked=true where id=invite_id and public.cb_project_access(project_id,'invite') and accepted_at is null;
 if not found then raise exception 'Invitation cannot be revoked';end if;
end; $$;
drop policy if exists invites_create on public.cb_invites;
create policy invites_create on public.cb_invites for insert to authenticated with check(created_by=auth.uid() and public.cb_project_access(project_id,'invite') and
 (role not in ('planner','bride') or public.cb_project_access(project_id,'owner')) and
 (not transfer_ownership or (role='bride' and public.cb_project_access(project_id,'owner') and exists(select 1 from public.cb_profiles where user_id=auth.uid() and account_type='planner'))));
drop policy if exists invites_read on public.cb_invites;
create policy invites_read on public.cb_invites for select to authenticated using(public.cb_project_access(project_id,'invite'));
drop policy if exists members_read on public.cb_members;
create policy members_read on public.cb_members for select to authenticated using(user_id=auth.uid() or public.cb_project_access(project_id,'invite'));
drop policy if exists collab_roles_read on public.cb_collab_roles;
create policy collab_roles_read on public.cb_collab_roles for select to authenticated using(public.cb_project_access(project_id,'read') and (public.cb_project_access(project_id,'owner') or exists(select 1 from public.cb_collab_access a where a.project_id=cb_collab_roles.project_id and a.user_id=auth.uid() and a.role_id=cb_collab_roles.id)));
drop policy if exists collab_access_read on public.cb_collab_access;
create policy collab_access_read on public.cb_collab_access for select to authenticated using(public.cb_project_access(project_id,'read') and (user_id=auth.uid() or public.cb_project_access(project_id,'owner')));
create or replace function public.cb_save_collab_role(p_project uuid,p_id uuid,p_revision bigint,p_title text,p_grants text[]) returns public.cb_collab_roles
language plpgsql security definer set search_path='' as $$
declare result public.cb_collab_roles;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'owner') then raise exception 'Only the owner can change access roles' using errcode='42501';end if;
 if p_grants is null or not p_grants <@ array['planning.write','events.read','finance.read','team.invite']::text[] or array_position(p_grants,null) is not null then raise exception 'Choose supported permissions';end if;
 if 'planning.write'=any(p_grants) and not 'events.read'=any(p_grants) then raise exception 'Planning editors need event schedule access';end if;
 if p_id is null then
  if (select count(*) from public.cb_collab_roles where project_id=p_project)>=30 then raise exception 'This wedding already has 30 custom roles';end if;
  insert into public.cb_collab_roles(project_id,title,grants) values(p_project,btrim(p_title),p_grants) returning * into result;
 else
  update public.cb_collab_roles set title=btrim(p_title),grants=p_grants,revision=revision+1,updated_at=now() where id=p_id and project_id=p_project and revision=p_revision returning * into result;
  if not found then raise exception 'Access role changed. Reload before saving.' using errcode='PT409';end if;
 end if;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Custom access role saved');return result;
end; $$;
create or replace function public.cb_assign_collab_role(p_project uuid,p_user uuid,p_role uuid,p_expires timestamptz,p_revision bigint) returns public.cb_collab_access
language plpgsql security definer set search_path='' as $$
declare result public.cb_collab_access;current_revision bigint;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'owner') then raise exception 'Only the owner can assign access roles' using errcode='42501';end if;
 if not exists(select 1 from public.cb_members where project_id=p_project and user_id=p_user) then raise exception 'Choose an accepted teammate';end if;
 if p_role is not null and not exists(select 1 from public.cb_collab_roles where project_id=p_project and id=p_role) then raise exception 'Choose a role from this wedding';end if;
 select revision into current_revision from public.cb_collab_access where project_id=p_project and user_id=p_user;
 if coalesce(current_revision,0) is distinct from p_revision then raise exception 'Access changed. Reload before saving.' using errcode='PT409';end if;
 insert into public.cb_collab_access(project_id,user_id,role_id,expires_at) values(p_project,p_user,p_role,p_expires)
 on conflict(project_id,user_id) do update set role_id=excluded.role_id,expires_at=excluded.expires_at,revision=cb_collab_access.revision+1 returning * into result;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Custom team access assigned');return result;
end; $$;
create or replace function public.cb_collab_context(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding access denied' using errcode='42501';end if;
 return jsonb_build_object('owner',public.cb_project_access(p_project,'owner'),'write',public.cb_project_access(p_project,'write'),'invite',public.cb_project_access(p_project,'invite'),'finance',public.cb_project_access(p_project,'finance'),'events',public.cb_project_access(p_project,'events'));
end; $$;
create or replace function public.cb_save_stakeholder(p_project uuid,p_ref text,p_revision bigint,p_title text,p_email text,p_phone text,p_relationship text,p_responsibilities text) returns public.cb_stakeholders
language plpgsql security definer set search_path='' as $$
declare result public.cb_stakeholders;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'invite') then raise exception 'Directory editing access denied' using errcode='42501';end if;
 if p_ref is null or length(p_ref) not between 1 and 200 then raise exception 'Invalid contact reference';end if;
 if coalesce(p_email,'')<>'' and p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email';end if;
 select * into result from public.cb_stakeholders where project_id=p_project and local_ref=p_ref for update;
 if coalesce(result.revision,0) is distinct from p_revision then raise exception 'Contact changed. Reload before saving.' using errcode='PT409';end if;
 insert into public.cb_stakeholders(project_id,local_ref,title,email,phone,relationship,responsibilities)
 values(p_project,p_ref,btrim(p_title),lower(btrim(coalesce(p_email,''))),coalesce(p_phone,''),coalesce(p_relationship,''),coalesce(p_responsibilities,''))
 on conflict(project_id,local_ref) do update set title=excluded.title,email=excluded.email,phone=excluded.phone,relationship=excluded.relationship,responsibilities=excluded.responsibilities,revision=cb_stakeholders.revision+1,updated_at=now() returning * into result;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Shared stakeholder saved');return result;
end; $$;
create or replace function public.cb_stakeholder_directory(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Directory access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(to_jsonb(s)||jsonb_build_object('linked_user_id',u.id,'account_status',case when u.id is null then 'Not connected' when a.expires_at<=now() then 'Access expired' else 'Connected' end) order by s.title),'[]')
 from public.cb_stakeholders s left join auth.users u on lower(u.email)=s.email and u.email_confirmed_at is not null and
 (exists(select 1 from public.cb_members m where m.project_id=p_project and m.user_id=u.id) or exists(select 1 from public.cb_projects p where p.id=p_project and p.owner_id=u.id))
 left join public.cb_collab_access a on a.project_id=p_project and a.user_id=u.id
 where s.project_id=p_project and (public.cb_project_access(p_project,'invite') or u.id=auth.uid()));
end; $$;
revoke all on function public.cb_save_collab_role(uuid,uuid,bigint,text,text[]),public.cb_assign_collab_role(uuid,uuid,uuid,timestamptz,bigint),public.cb_collab_context(uuid),public.cb_save_stakeholder(uuid,text,bigint,text,text,text,text,text),public.cb_stakeholder_directory(uuid) from public,anon,authenticated;
grant execute on function public.cb_save_collab_role(uuid,uuid,bigint,text,text[]),public.cb_assign_collab_role(uuid,uuid,uuid,timestamptz,bigint),public.cb_collab_context(uuid),public.cb_save_stakeholder(uuid,text,bigint,text,text,text,text,text),public.cb_stakeholder_directory(uuid) to authenticated;

-- Background notification/email processing must use the same expiry and permissions.
do $migration$
declare definition text; repaired text;
begin
 if to_regprocedure('public.cb_planning_can_view(uuid,uuid,text,uuid)') is not null then
 execute $fn$create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $body$
 select public.cb_collab_user_access(p_user,p_project,'read') and exists(
 select 1 from public.cb_projects p join auth.users u on u.id=p_user
 left join public.cb_members m on m.project_id=p.id and m.user_id=u.id
 where p.id=p_project and p.archived_at is null and case p_kind
 when 'project' then p_source=p.id
 when 'task' then exists(select 1 from public.cb_tasks t where t.id=p_source and t.project_id=p.id and
 (public.cb_collab_user_access(p_user,p.id,'write') or lower(t.assignee_email)=lower(u.email) or (t.approval_required and lower(t.approver_email)=lower(u.email))))
 when 'event' then public.cb_collab_user_access(p_user,p.id,'events') and exists(select 1 from public.cb_project_events e where e.id=p_source and e.project_id=p.id and
 (public.cb_collab_user_access(p_user,p.id,'write') or (e.visibility='team' and m.role in ('family','sibling','friend','bridal-party')) or exists(select 1 from public.cb_project_event_members em where em.event_id=e.id and em.user_id=u.id)))
 else false end);
 $body$ $fn$;
 end if;
 if to_regprocedure('public.cb_process_invitation_email()') is not null then
  select pg_get_functiondef('public.cb_process_invitation_email()'::regprocedure) into definition;
  repaired=replace(definition,'m.user_id=j.requested_by and m.role in (''bride'',''planner'')','m.user_id=j.requested_by and public.cb_collab_user_access(m.user_id,p.id,''invite'')');
  if repaired<>definition then execute repaired;end if;
 end if;
end; $migration$;

notify pgrst,'reload schema';
commit;
