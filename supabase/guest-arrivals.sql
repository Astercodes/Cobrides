-- Private, event-specific guest arrivals. Run after shared-seating.sql.
begin;
create table if not exists public.cb_guest_arrivals(
 event_id uuid not null references public.cb_project_events on delete cascade,
 household_id uuid not null references public.cb_rsvp_households on delete cascade,guest_id uuid not null,
 guest_name text not null,household_name text not null,arrived boolean not null,arrived_at timestamptz not null,
 note text not null default '',revision bigint not null default 1,updated_by uuid not null references auth.users,updated_at timestamptz not null default now(),
 primary key(event_id,household_id,guest_id)
);
alter table public.cb_guest_arrivals enable row level security;
revoke all on public.cb_guest_arrivals from public,anon,authenticated;
do $$begin if to_regprocedure('public.cb_seating_workspace_base(uuid,uuid)') is null then alter function public.cb_seating_workspace(uuid,uuid) rename to cb_seating_workspace_base;end if;end;$$;
create or replace function public.cb_seating_workspace(p_project uuid,p_event uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;chosen uuid;
begin
 result=public.cb_seating_workspace_base(p_project,p_event);chosen=(result->>'selected')::uuid;
 return result||jsonb_build_object('arrivals',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('needs_review',a.arrived and not public.cb_confirmed_guest(a.household_id,a.guest_id,a.event_id)) order by a.arrived_at desc,a.household_id,a.guest_id),'[]') from public.cb_guest_arrivals a where event_id=chosen));
end;$$;
create or replace function public.cb_set_guest_arrival(p_event uuid,p_household uuid,p_guest uuid,p_revision bigint,p_client uuid,p_arrived boolean,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;a public.cb_guest_arrivals;prior public.cb_seating_writes;payload jsonb;result jsonb;person_name text;family_name text;present boolean;
begin
 select project_id into pid from public.cb_project_events where id=p_event;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'write') and public.cb_project_event_access(p_event),false) then raise exception 'Guest check-in access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','arrival','event',p_event,'household',p_household,'guest',p_guest,'revision',p_revision,'arrived',p_arrived,'note',p_note);
 if p_client is null then raise exception 'Request ID required';end if;
 select * into prior from public.cb_seating_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prior.payload is distinct from payload then raise exception 'Arrival changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if p_arrived is null or p_note is null or length(p_note)>1000 then raise exception 'Check the arrival status and note';end if;
 select * into a from public.cb_guest_arrivals where event_id=p_event and household_id=p_household and guest_id=p_guest for update;present=found;
 if coalesce(a.revision,0) is distinct from p_revision then raise exception 'Arrival changed. Refresh before updating.' using errcode='PT409';end if;
 if p_arrived then
 if not public.cb_confirmed_guest(p_household,p_guest,p_event) then raise exception 'Check in only a currently confirmed guest for this celebration';end if;
 if present and a.arrived then raise exception 'This guest is already checked in. Refresh to see their arrival.' using errcode='PT409';end if;
 select m->>'name',h.data->>'title' into person_name,family_name from public.cb_rsvp_households h cross join lateral jsonb_array_elements(h.data->'members') m where h.id=p_household and h.project_id=pid and m->>'id'=p_guest::text;
 insert into public.cb_guest_arrivals(event_id,household_id,guest_id,guest_name,household_name,arrived,arrived_at,note,updated_by)
 values(p_event,p_household,p_guest,person_name,family_name,true,now(),btrim(p_note),auth.uid())
 on conflict(event_id,household_id,guest_id) do update set guest_name=excluded.guest_name,household_name=excluded.household_name,arrived=true,arrived_at=now(),note=excluded.note,revision=cb_guest_arrivals.revision+1,updated_by=auth.uid(),updated_at=now() returning * into a;
 else
 if not present or not a.arrived then raise exception 'This guest is not currently checked in. Refresh before correcting.' using errcode='PT409';end if;
 if length(btrim(p_note))<1 then raise exception 'Add a reason for correcting this arrival';end if;
 update public.cb_guest_arrivals set arrived=false,note=btrim(p_note),revision=revision+1,updated_by=auth.uid(),updated_at=now() where event_id=p_event and household_id=p_household and guest_id=p_guest returning * into a;
 end if;
 result=to_jsonb(a);insert into public.cb_seating_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_seating_history(event_id,actor_id,kind,data) values(p_event,auth.uid(),case when p_arrived then 'Guest checked in' else 'Guest arrival corrected' end,result);
 return result;
end;$$;
revoke all on function public.cb_seating_workspace_base(uuid,uuid),public.cb_seating_workspace(uuid,uuid),public.cb_set_guest_arrival(uuid,uuid,uuid,bigint,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.cb_seating_workspace(uuid,uuid),public.cb_set_guest_arrival(uuid,uuid,uuid,bigint,uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';commit;
