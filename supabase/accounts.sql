-- Run after collaboration.sql. This migration adds authenticated account profiles.
create table public.cb_profiles(user_id uuid primary key references auth.users on delete cascade, full_name text not null check(length(full_name) between 1 and 100),account_type text not null check(account_type in ('bride','planner','partner','bridal-party','family','vendor','merchant','venue','guest','collaborator')),business_name text not null default '' check(length(business_name)<=160),is_admin boolean not null default false,created_at timestamptz not null default now(),check(account_type not in ('planner','vendor','merchant','venue') or length(trim(business_name))>0));
alter table public.cb_profiles enable row level security;
create policy profiles_read on public.cb_profiles for select to authenticated using(user_id=auth.uid());
create policy profiles_create on public.cb_profiles for insert to authenticated with check(user_id=auth.uid() and not is_admin);
create policy profiles_edit on public.cb_profiles for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
revoke all on public.cb_profiles from anon,authenticated;
grant select on public.cb_profiles to authenticated;
grant insert(user_id,full_name,account_type,business_name) on public.cb_profiles to authenticated;
grant update(full_name,business_name) on public.cb_profiles to authenticated;

-- Billing records are written by verified payment webhooks, never by a browser.
create table public.cb_subscriptions(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users,plan text not null check(plan in ('monthly','quarterly','six-months','annual')),status text not null check(status in ('active','expired','cancelled')),period_start timestamptz not null,period_end timestamptz not null check(period_end>period_start),auto_renew boolean not null default false,provider_reference text unique,created_at timestamptz not null default now());
alter table public.cb_subscriptions enable row level security;
create policy subscriptions_read on public.cb_subscriptions for select to authenticated using(user_id=auth.uid());
revoke all on public.cb_subscriptions from anon,authenticated;
grant select on public.cb_subscriptions to authenticated;
create function public.cb_has_premium() returns boolean language sql stable security invoker set search_path='' as $$ select exists(select 1 from public.cb_subscriptions where user_id=auth.uid() and status='active' and period_start<=now() and period_end>now()); $$;
revoke all on function public.cb_has_premium() from public,anon;
grant execute on function public.cb_has_premium() to authenticated;

-- Both brides and planners can create projects, and owners can invite a bride.
alter table public.cb_members drop constraint cb_members_role_check;
alter table public.cb_members add constraint cb_members_role_check check(role in ('bride','planner','partner','family','bridal-party','vendor','guest'));
alter table public.cb_invites drop constraint cb_invites_role_check;
alter table public.cb_invites add constraint cb_invites_role_check check(role in ('bride','planner','partner','family','bridal-party','vendor','guest'));
alter table public.cb_invites add column created_by uuid references auth.users default auth.uid(),add column transfer_ownership boolean not null default false;
create or replace function public.cb_manager(pid uuid) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.cb_projects where id=pid and owner_id=auth.uid()) or exists(select 1 from public.cb_members where project_id=pid and user_id=auth.uid() and role in ('planner','bride')); $$;
drop policy invites_create on public.cb_invites;
create policy invites_create on public.cb_invites for insert to authenticated with check(created_by=auth.uid() and public.cb_manager(project_id) and (role not in ('planner','bride') or exists(select 1 from public.cb_projects where id=project_id and owner_id=auth.uid())) and (not transfer_ownership or (role='bride' and exists(select 1 from public.cb_projects where id=project_id and owner_id=auth.uid()) and exists(select 1 from public.cb_profiles where user_id=auth.uid() and account_type='planner'))));
create or replace function public.cb_accept_invite(invite_token uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare invitation public.cb_invites; old_owner uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into invitation from public.cb_invites where token=invite_token for update;
 if not found or invitation.revoked or invitation.expires_at<now() or invitation.accepted_at is not null then raise exception 'Invitation is expired, revoked or already accepted'; end if;
 if lower(invitation.email)<>lower(coalesce(auth.jwt()->>'email','')) then raise exception 'Sign in with the invited email address'; end if;
 select owner_id into old_owner from public.cb_projects where id=invitation.project_id for update;
 if old_owner=auth.uid() then raise exception 'You already own this project'; end if;
 if invitation.transfer_ownership then
   if invitation.role<>'bride' or invitation.created_by is distinct from old_owner or not exists(select 1 from public.cb_profiles where user_id=old_owner and account_type='planner') then raise exception 'The project owner changed. Request a new bride invitation'; end if;
   insert into public.cb_members(project_id,user_id,role) values(invitation.project_id,old_owner,'planner') on conflict(project_id,user_id) do update set role='planner';
   update public.cb_projects set owner_id=auth.uid() where id=invitation.project_id;
 end if;
 insert into public.cb_members(project_id,user_id,role) values(invitation.project_id,auth.uid(),invitation.role) on conflict do nothing;
 update public.cb_invites set accepted_at=now() where id=invitation.id;
 return invitation.project_id;
end; $$;
