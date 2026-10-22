-- Private, encrypted provider connections and single-use OAuth flows.
begin;
create table if not exists public.cb_social_connections (
 user_id uuid not null references auth.users on delete cascade,
 provider text not null check(provider='pinterest'),
 ciphertext text not null check(length(ciphertext)<=20000),
 updated_at timestamptz not null default now(),
 primary key(user_id,provider)
);
create table if not exists public.cb_social_oauth_flows (
 id uuid primary key,
 user_id uuid not null references auth.users on delete cascade,
 expires_at timestamptz not null
);
alter table public.cb_social_connections enable row level security;
alter table public.cb_social_oauth_flows enable row level security;
drop policy if exists cb_connections_owner on public.cb_social_connections;
create policy cb_connections_owner on public.cb_social_connections for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists cb_oauth_owner on public.cb_social_oauth_flows;
create policy cb_oauth_owner on public.cb_social_oauth_flows for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
revoke all on public.cb_social_connections,public.cb_social_oauth_flows from anon,public;
grant select,insert,update,delete on public.cb_social_connections,public.cb_social_oauth_flows to authenticated;
commit;
