begin;
alter table public.cb_members drop constraint if exists cb_members_role_check;
alter table public.cb_members add constraint cb_members_role_check check(role in ('bride','planner','partner','family','sibling','friend','bridal-party','vendor','guest'));
alter table public.cb_invites drop constraint if exists cb_invites_role_check;
alter table public.cb_invites add constraint cb_invites_role_check check(role in ('bride','planner','partner','family','sibling','friend','bridal-party','vendor','guest'));
create or replace function public.cb_set_project_member(p_project uuid,p_user uuid,p_role text,p_financial_access boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'owner') then raise exception 'Only the owner can change team permissions';end if;
 if p_role not in ('bride','planner','partner','family','sibling','friend','bridal-party','vendor','guest') then raise exception 'Choose an available role';end if;
 update public.cb_members set role=p_role,financial_access=p_financial_access where project_id=p_project and user_id=p_user;
 if not found then raise exception 'Team member not found';end if;
 update public.cb_projects set revision=revision+1,updated_at=now() where id=p_project;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Team permissions updated');
end; $$;
create or replace function public.cb_project_event_access(eid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_project_events e where e.id=eid and public.cb_project_access(e.project_id,'read') and
 (public.cb_project_access(e.project_id,'write') or (e.visibility='team' and exists(select 1 from public.cb_members m where m.project_id=e.project_id and m.user_id=auth.uid() and m.role in ('family','sibling','friend','bridal-party')))
 or exists(select 1 from public.cb_project_event_members where event_id=e.id and user_id=auth.uid())));
$$;
notify pgrst, 'reload schema';
commit;
