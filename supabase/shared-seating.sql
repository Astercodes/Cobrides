-- Shared seating and catering, based on confirmed native RSVPs.
begin;
create table if not exists public.cb_seating_events(event_id uuid primary key references public.cb_project_events on delete cascade,revision bigint not null default 0);
create table if not exists public.cb_seating_tables(id uuid primary key default gen_random_uuid(),event_id uuid not null references public.cb_project_events on delete cascade,title text not null,capacity integer not null check(capacity between 1 and 100),shape text not null,zone text not null default '',notes text not null default '',archived boolean not null default false,revision bigint not null default 1,updated_at timestamptz not null default now());
create unique index if not exists cb_seating_table_name on public.cb_seating_tables(event_id,lower(btrim(title))) where not archived;
create table if not exists public.cb_guest_seats(event_id uuid not null references public.cb_project_events on delete cascade,household_id uuid not null references public.cb_rsvp_households on delete cascade,guest_id uuid not null,table_id uuid not null references public.cb_seating_tables on delete cascade,primary key(event_id,household_id,guest_id));
create index if not exists cb_guest_seats_table on public.cb_guest_seats(table_id);
create table if not exists public.cb_seating_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_seating_history(id bigint generated always as identity primary key,event_id uuid not null references public.cb_project_events on delete cascade,actor_id uuid references auth.users,kind text not null,data jsonb not null,at timestamptz not null default now());
alter table public.cb_seating_events enable row level security;alter table public.cb_seating_tables enable row level security;alter table public.cb_guest_seats enable row level security;alter table public.cb_seating_writes enable row level security;alter table public.cb_seating_history enable row level security;
revoke all on public.cb_seating_events,public.cb_seating_tables,public.cb_guest_seats,public.cb_seating_writes,public.cb_seating_history from public,anon,authenticated;
create or replace function public.cb_confirmed_guest(p_household uuid,p_guest uuid,p_event uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_rsvp_households h join public.cb_project_events e on e.project_id=h.project_id where h.id=p_household and e.id=p_event and exists(select 1 from jsonb_array_elements(h.data->'members') m where m->>'id'=p_guest::text and m->'events' ? p_event::text) and exists(select 1 from jsonb_array_elements(h.answers) a where a->>'guest'=p_guest::text and a->>'event'=p_event::text and a->>'status'='Confirmed'));
$$;
create or replace function public.cb_seating_rsvp_sync() returns trigger language plpgsql security definer set search_path='' as $$
declare seat record;event_ref uuid;
begin
 for seat in delete from public.cb_guest_seats s where s.household_id=new.id and not public.cb_confirmed_guest(s.household_id,s.guest_id,s.event_id) returning * loop
 insert into public.cb_seating_history(event_id,actor_id,kind,data) values(seat.event_id,auth.uid(),'Seat released after RSVP change',to_jsonb(seat));end loop;
 for event_ref in select distinct e.id from public.cb_project_events e cross join lateral jsonb_array_elements((old.data->'members')||(new.data->'members')) m where e.project_id=new.project_id and m->'events' ? e.id::text loop
 insert into public.cb_seating_events values(event_ref,1) on conflict(event_id) do update set revision=cb_seating_events.revision+1;end loop;
 return new;
end;$$;
drop trigger if exists cb_seating_rsvp_updated on public.cb_rsvp_households;
create trigger cb_seating_rsvp_updated after update of answers,data on public.cb_rsvp_households for each row execute function public.cb_seating_rsvp_sync();
create or replace function public.cb_seating_workspace(p_project uuid,p_event uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare chosen uuid;
begin
 if not public.cb_project_access(p_project,'write') then raise exception 'Guest management access required' using errcode='42501';end if;
 if p_event is not null and not exists(select 1 from public.cb_project_events where id=p_event and project_id=p_project and public.cb_project_event_access(id)) then raise exception 'Celebration access required' using errcode='42501';end if;
 chosen=coalesce(p_event,(select id from public.cb_project_events where project_id=p_project and public.cb_project_event_access(id) order by details->>'date',title,id limit 1));
 return jsonb_build_object('project',p_project,'selected',chosen,'revision',coalesce((select revision from public.cb_seating_events where event_id=chosen),0),
 'events',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'date',details->>'date') order by details->>'date',title),'[]') from public.cb_project_events where project_id=p_project and public.cb_project_event_access(id)),
 'tables',(select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('occupied',(select count(*) from public.cb_guest_seats where table_id=t.id)) order by archived,lower(title),id),'[]') from public.cb_seating_tables t where event_id=chosen),
 'guests',(select coalesce(jsonb_agg(jsonb_build_object('household',h.id,'guest',m->>'id','name',m->>'name','household_title',h.data->>'title','meal',a->>'meal','diet',a->>'diet','access',a->>'access','table',s.table_id) order by lower(m->>'name'),h.id),'[]') from public.cb_rsvp_households h cross join lateral jsonb_array_elements(h.data->'members') m cross join lateral jsonb_array_elements(h.answers) a left join public.cb_guest_seats s on s.household_id=h.id and s.guest_id::text=m->>'id' and s.event_id=chosen where h.project_id=p_project and m->'events' ? chosen::text and a->>'guest'=m->>'id' and a->>'event'=chosen::text and a->>'status'='Confirmed'),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]') from (select id,kind,at from public.cb_seating_history where event_id=chosen order by id desc limit 30) x));
end;$$;
create or replace function public.cb_save_seating_table(p_event uuid,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;t public.cb_seating_tables;prior public.cb_seating_writes;payload jsonb;result jsonb;k text;
begin
 select project_id into pid from public.cb_project_events where id=p_event;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'write') and public.cb_project_event_access(p_event),false) then raise exception 'Seating management access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','table','event',p_event,'id',p_id,'revision',p_revision,'data',p_data);if p_client is null then raise exception 'Request ID required';end if;
 select * into prior from public.cb_seating_writes where user_id=auth.uid() and client_id=p_client;if found then if prior.payload is distinct from payload then raise exception 'Table changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>6000 or p_data-array['title','capacity','shape','zone','notes','archived']::text[]<>'{}' then raise exception 'Review table details';end if;
 foreach k in array array['title','shape','zone','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k='notes' then 2000 else 160 end) then raise exception 'Review table text';end if;end loop;
 if length(btrim(p_data->>'title')) not between 1 and 120 or jsonb_typeof(p_data->'capacity') is distinct from 'number' or p_data->>'capacity' !~ '^\d{1,3}$' or (p_data->>'capacity')::integer not between 1 and 100 or p_data->>'shape' not in ('Round','Rectangle','Long table') or jsonb_typeof(p_data->'archived') is distinct from 'boolean' then raise exception 'Choose a table name, shape and capacity from one to one hundred';end if;
 if not (p_data->>'archived')::boolean and exists(select 1 from public.cb_seating_tables where event_id=p_event and not archived and lower(btrim(title))=lower(btrim(p_data->>'title')) and (p_id is null or id<>p_id)) then raise exception 'Choose a different table name for this celebration';end if;
 if p_id is null then
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating a table' using errcode='PT409';end if;
 if (select count(*) from public.cb_seating_tables where event_id=p_event)>=300 then raise exception 'This celebration has reached its table allowance';end if;
 insert into public.cb_seating_tables(event_id,title,capacity,shape,zone,notes,archived) values(p_event,btrim(p_data->>'title'),(p_data->>'capacity')::integer,p_data->>'shape',p_data->>'zone',p_data->>'notes',(p_data->>'archived')::boolean) returning * into t;
 else
 select * into t from public.cb_seating_tables where id=p_id and event_id=p_event;if not found then raise exception 'Table access required' using errcode='42501';end if;
 if t.revision is distinct from p_revision then raise exception 'Table changed. Refresh before editing.' using errcode='PT409';end if;
 if (select count(*) from public.cb_guest_seats where table_id=t.id)>(p_data->>'capacity')::integer then raise exception 'Move guests before reducing this table capacity';end if;
 if (p_data->>'archived')::boolean and exists(select 1 from public.cb_guest_seats where table_id=t.id) then raise exception 'Move guests before archiving this table';end if;
 update public.cb_seating_tables set title=btrim(p_data->>'title'),capacity=(p_data->>'capacity')::integer,shape=p_data->>'shape',zone=p_data->>'zone',notes=p_data->>'notes',archived=(p_data->>'archived')::boolean,revision=revision+1,updated_at=now() where id=t.id returning * into t;
 end if;
 insert into public.cb_seating_events values(p_event,1) on conflict(event_id) do update set revision=cb_seating_events.revision+1;
 result=to_jsonb(t);insert into public.cb_seating_history(event_id,actor_id,kind,data) values(p_event,auth.uid(),'Table saved',result);insert into public.cb_seating_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_assign_guest_seat(p_event uuid,p_revision bigint,p_client uuid,p_household uuid,p_guest uuid,p_table uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;t public.cb_seating_tables;prior public.cb_seating_writes;payload jsonb;result jsonb;current_revision bigint;
begin
 select project_id into pid from public.cb_project_events where id=p_event;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'write') and public.cb_project_event_access(p_event),false) then raise exception 'Seating management access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','seat','event',p_event,'revision',p_revision,'household',p_household,'guest',p_guest,'table',p_table);if p_client is null then raise exception 'Request ID required';end if;
 select * into prior from public.cb_seating_writes where user_id=auth.uid() and client_id=p_client;if found then if prior.payload is distinct from payload then raise exception 'Seat changed during retry' using errcode='PT409';end if;return prior.response;end if;
 select coalesce((select revision from public.cb_seating_events where event_id=p_event),0) into current_revision;if current_revision is distinct from p_revision then raise exception 'Seating or RSVPs changed. Refresh before assigning.' using errcode='PT409';end if;
 if not public.cb_confirmed_guest(p_household,p_guest,p_event) then raise exception 'Seat only a currently confirmed guest at their invited celebration';end if;
 if p_table is not null then
 select * into t from public.cb_seating_tables where id=p_table and event_id=p_event and not archived;if not found then raise exception 'Choose an active table in this celebration';end if;
 if (select count(*) from public.cb_guest_seats where table_id=t.id and not (household_id=p_household and guest_id=p_guest))>=t.capacity then raise exception 'This table is full. Choose another table.';end if;
 insert into public.cb_guest_seats values(p_event,p_household,p_guest,p_table) on conflict(event_id,household_id,guest_id) do update set table_id=excluded.table_id;
 else delete from public.cb_guest_seats where event_id=p_event and household_id=p_household and guest_id=p_guest;end if;
 insert into public.cb_seating_events values(p_event,1) on conflict(event_id) do update set revision=cb_seating_events.revision+1 returning revision into current_revision;
 result=jsonb_build_object('saved',true,'revision',current_revision);insert into public.cb_seating_writes values(auth.uid(),p_client,payload,result);insert into public.cb_seating_history(event_id,actor_id,kind,data) values(p_event,auth.uid(),'Guest seat updated',payload);return result;
end;$$;
revoke all on function public.cb_confirmed_guest(uuid,uuid,uuid),public.cb_seating_rsvp_sync(),public.cb_seating_workspace(uuid,uuid),public.cb_save_seating_table(uuid,uuid,bigint,uuid,jsonb),public.cb_assign_guest_seat(uuid,bigint,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.cb_seating_workspace(uuid,uuid),public.cb_save_seating_table(uuid,uuid,bigint,uuid,jsonb),public.cb_assign_guest_seat(uuid,bigint,uuid,uuid,uuid,uuid) to authenticated;
notify pgrst,'reload schema';commit;
