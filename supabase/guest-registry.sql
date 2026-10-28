-- Private invitation-bound guest gift reservations. Run after shared-registry.sql and guest-rsvp.sql.
begin;
alter table public.cb_registry_reservations alter column created_by drop not null;
alter table public.cb_registry_reservations add column if not exists household_id uuid references public.cb_rsvp_households(id);
alter table public.cb_registry_reservations add column if not exists guest_snapshot jsonb;
create table if not exists public.cb_registry_guest_visibility(entry_id uuid primary key references public.cb_registry_entries(id),enabled boolean not null default false,approved_by uuid not null,updated_at timestamptz not null default now());
create table if not exists public.cb_registry_guest_writes(household_id uuid not null references public.cb_rsvp_households(id),client uuid not null,payload jsonb not null,response jsonb not null,at timestamptz not null default now(),primary key(household_id,client));
alter table public.cb_registry_guest_visibility enable row level security;alter table public.cb_registry_guest_writes enable row level security;
revoke all on public.cb_registry_guest_visibility,public.cb_registry_guest_writes from public,anon,authenticated;
create or replace function public.cb_registry_guest_visibility_set(p_entry uuid,p_revision bigint,p_enabled boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_registry_entries;v public.cb_registry_guest_visibility;
begin
 select * into e from public.cb_registry_entries where id=p_entry;if not found then raise exception 'Gift unavailable' using errcode='42501';end if;
 perform 1 from public.cb_projects where id=e.project_id for update;
 if not coalesce(public.cb_project_access(e.project_id,'owner'),false) then raise exception 'Only the wedding owner can share gifts with guests' using errcode='42501';end if;
 select * into e from public.cb_registry_entries where id=p_entry for update;
 if p_enabled is null or p_revision is null then raise exception 'Review the gift first';end if;
 select * into v from public.cb_registry_guest_visibility where entry_id=p_entry;
 if v.enabled is not distinct from p_enabled and e.revision=p_revision+1 and v.approved_by=auth.uid() then return to_jsonb(e);end if;
 if e.revision<>p_revision then raise exception 'Gift changed. Refresh first.' using errcode='PT409';end if;
 if p_enabled and coalesce((e.data->>'archived')::boolean,false) then raise exception 'Restore this gift before sharing';end if;
 insert into public.cb_registry_guest_visibility values(p_entry,p_enabled,auth.uid(),now()) on conflict(entry_id) do update set enabled=excluded.enabled,approved_by=excluded.approved_by,updated_at=now();
 update public.cb_registry_entries set revision=revision+1,updated_at=now() where id=p_entry returning * into e;
 insert into public.cb_registry_history(project_id,record_id,actor,action,snapshot) values(e.project_id,e.id,auth.uid(),'guest visibility',jsonb_build_object('enabled',p_enabled,'revision',e.revision));return to_jsonb(e);
end;$$;
-- Read sharing status alongside manager records without changing existing registry RPC signatures.
do $$begin if to_regprocedure('public.cb_registry_workspace_before_guests(uuid)') is null then alter function public.cb_registry_workspace(uuid) rename to cb_registry_workspace_before_guests;end if;end$$;
create or replace function public.cb_registry_workspace(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;begin
 result=public.cb_registry_workspace_before_guests(p_project);
 return result||jsonb_build_object('owner',public.cb_project_access(p_project,'owner'),'items',(select coalesce(jsonb_agg(item||jsonb_build_object('guest_visible',coalesce(v.enabled and v.approved_by=p.owner_id,false))),'[]') from jsonb_array_elements(result->'items') item left join public.cb_registry_guest_visibility v on v.entry_id=(item->>'id')::uuid join public.cb_projects p on p.id=p_project));
end;$$;
create or replace function public.cb_guest_registry(p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare h public.cb_rsvp_households;begin
 if p_token!~'^[a-f0-9]{64}$' then return null;end if;
 select hh.* into h from public.cb_rsvp_households hh join public.cb_projects p on p.id=hh.project_id where hh.token=p_token and not hh.revoked and p.archived_at is null;if not found then return null;end if;
 return jsonb_build_object('items',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'revision',e.revision,'title',e.data->>'title','url',e.data->>'url','image',e.data->>'image','category',e.data->>'category','merchant',e.data->>'merchant','remaining',greatest(0,(e.data->>'quantity')::integer-(select coalesce(sum(quantity),0) from public.cb_registry_reservations where entry_id=e.id and status not in ('Cancelled','Returned')))) order by e.updated_at desc),'[]') from public.cb_registry_entries e join public.cb_registry_guest_visibility v on v.entry_id=e.id join public.cb_projects p on p.id=e.project_id where e.project_id=h.project_id and v.enabled and v.approved_by=p.owner_id and not coalesce((e.data->>'archived')::boolean,false)),
 'reservations',(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'entry',g.entry_id,'title',g.guest_snapshot->>'title','url',g.guest_snapshot->>'url','quantity',g.quantity,'status',g.status,'revision',g.revision) order by g.updated_at desc),'[]') from public.cb_registry_reservations g join public.cb_registry_entries e on e.id=g.entry_id where g.household_id=h.id and e.project_id=h.project_id));
end;$$;
create or replace function public.cb_guest_registry_write(p_token text,p_entry uuid,p_id uuid,p_revision bigint,p_client uuid,p_quantity integer,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_rsvp_households;e public.cb_registry_entries;g public.cb_registry_reservations;old public.cb_registry_guest_writes;payload jsonb;result jsonb;used integer;pid uuid;
begin
 select project_id into pid from public.cb_rsvp_households where token=p_token and not revoked;if not found then raise exception 'Invitation unavailable' using errcode='42501';end if;
 perform 1 from public.cb_projects where id=pid and archived_at is null for update;if not found then raise exception 'Invitation unavailable' using errcode='42501';end if;
 select * into h from public.cb_rsvp_households where token=p_token and not revoked for share;if not found then raise exception 'Invitation unavailable' using errcode='42501';end if;
 if p_client is null or p_revision is null or p_quantity is null or p_quantity not between 1 and 9999 or p_action not in ('reserve','purchased','cancel') or p_action is null then raise exception 'Review the reservation';end if;
 payload=jsonb_build_object('entry',p_entry,'id',p_id,'revision',p_revision,'quantity',p_quantity,'action',p_action);
 select * into old from public.cb_registry_guest_writes where household_id=h.id and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the original reservation' using errcode='PT409';end if;return old.response;end if;
 if (select count(*) from public.cb_registry_guest_writes where household_id=h.id and at>now()-interval '24 hours')>=30 then raise exception 'Please try again tomorrow or contact the couple' using errcode='PT429';end if;
 select * into e from public.cb_registry_entries where id=p_entry and project_id=pid for update;if not found then raise exception 'Gift unavailable';end if;
 if p_action='reserve' then
  if p_id is not null or e.revision<>p_revision then raise exception 'Gift changed. Refresh first.' using errcode='PT409';end if;
  if coalesce((e.data->>'archived')::boolean,false) or not exists(select 1 from public.cb_registry_guest_visibility v join public.cb_projects p on p.id=pid where v.entry_id=e.id and v.enabled and v.approved_by=p.owner_id) then raise exception 'Gift unavailable';end if;
  select coalesce(sum(quantity),0) into used from public.cb_registry_reservations where entry_id=e.id and status not in ('Cancelled','Returned');
  if used+p_quantity>(e.data->>'quantity')::integer then raise exception 'This quantity has already been reserved. Refresh and choose another gift.' using errcode='PT409';end if;
  insert into public.cb_registry_reservations(entry_id,giver,quantity,created_by,household_id,guest_snapshot) values(e.id,h.data->>'title',p_quantity,null,h.id,jsonb_build_object('title',e.data->>'title','url',e.data->>'url')) returning * into g;
 else
  select * into g from public.cb_registry_reservations where id=p_id and entry_id=e.id and household_id=h.id for update;
  if not found then raise exception 'Reservation unavailable' using errcode='42501';end if;
  if g.revision<>p_revision or g.quantity<>p_quantity then raise exception 'Reservation changed. Refresh first.' using errcode='PT409';end if;
  if g.status<>'Reserved' then raise exception 'Please contact the couple about changing this gift';end if;
  update public.cb_registry_reservations set status=case when p_action='purchased' then 'Purchased externally' else 'Cancelled' end,revision=revision+1,updated_at=now() where id=g.id returning * into g;
 end if;
 result=jsonb_build_object('id',g.id,'entry',g.entry_id,'status',g.status,'quantity',g.quantity,'revision',g.revision);
 insert into public.cb_registry_guest_writes values(h.id,p_client,payload,result,now());return result;
end;$$;
-- Editing a gift withdraws guest visibility until the current owner reviews it again.
do $$begin if to_regprocedure('public.cb_write_registry_before_guests(uuid,text,uuid,bigint,uuid,jsonb)') is null then alter function public.cb_write_registry(uuid,text,uuid,bigint,uuid,jsonb) rename to cb_write_registry_before_guests;end if;end$$;
create or replace function public.cb_write_registry(p_project uuid,p_kind text,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;begin
 result=public.cb_write_registry_before_guests(p_project,p_kind,p_id,p_revision,p_client,p_data);
 if p_kind='item' and exists(select 1 from public.cb_registry_entries where id=(result->>'id')::uuid and revision=(result->>'revision')::bigint) then update public.cb_registry_guest_visibility set enabled=false,updated_at=now() where entry_id=(result->>'id')::uuid;end if;return result;
end;$$;
revoke all on function public.cb_write_registry_before_guests(uuid,text,uuid,bigint,uuid,jsonb),public.cb_write_registry(uuid,text,uuid,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_write_registry(uuid,text,uuid,bigint,uuid,jsonb) to authenticated;
revoke all on function public.cb_registry_workspace_before_guests(uuid),public.cb_registry_workspace(uuid),public.cb_registry_guest_visibility_set(uuid,bigint,boolean),public.cb_guest_registry(text),public.cb_guest_registry_write(text,uuid,uuid,bigint,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.cb_registry_workspace(uuid),public.cb_registry_guest_visibility_set(uuid,bigint,boolean) to authenticated;
grant execute on function public.cb_guest_registry(text),public.cb_guest_registry_write(text,uuid,uuid,bigint,uuid,integer,text) to anon,authenticated;
notify pgrst,'reload schema';commit;
