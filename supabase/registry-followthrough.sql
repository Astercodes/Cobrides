-- Thank-you records and receipt-linked household inventory. Run after guest-registry.sql.
begin;
create table if not exists public.cb_registry_followups(gift_id uuid primary key references public.cb_registry_reservations(id),data jsonb not null,inventory_item jsonb,revision bigint not null default 1,updated_by uuid not null,updated_at timestamptz not null default now());
create table if not exists public.cb_registry_followup_writes(user_id uuid not null,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
alter table public.cb_registry_followups enable row level security;alter table public.cb_registry_followup_writes enable row level security;
revoke all on public.cb_registry_followups,public.cb_registry_followup_writes from public,anon,authenticated;
create or replace function public.cb_registry_followthrough(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Registry management access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'gifts',(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'entry',e.id,'giver',g.giver,'quantity',g.quantity,'status',g.status,'gift_revision',g.revision,'title',e.data->>'title','image',e.data->>'image','url',e.data->>'url','revision',coalesce(f.revision,0),'data',coalesce(f.data,jsonb_build_object('thanks','To write','message','','delivery','','room','Whole home','inventory',false,'notes','')),'inventory_item',f.inventory_item,'in_inventory',g.status='Received' and coalesce((f.data->>'inventory')::boolean,false)) order by g.updated_at desc,g.id),'[]') from public.cb_registry_reservations g join public.cb_registry_entries e on e.id=g.entry_id left join public.cb_registry_followups f on f.gift_id=g.id where e.project_id=p_project));
end;$$;
create or replace function public.cb_save_registry_followthrough(p_project uuid,p_gift uuid,p_gift_revision bigint,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.cb_registry_reservations;e public.cb_registry_entries;f public.cb_registry_followups;old public.cb_registry_followup_writes;payload jsonb;result jsonb;snapshot jsonb;k text;want_inventory boolean;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Registry management access required' using errcode='42501';end if;
 if p_client is null or p_revision is null or p_gift_revision is null then raise exception 'Review the gift before saving';end if;
 payload=jsonb_build_object('project',p_project,'gift',p_gift,'gift_revision',p_gift_revision,'revision',p_revision,'data',p_data);
 select * into old from public.cb_registry_followup_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the original details' using errcode='PT409';end if;return old.response;end if;
 select * into g from public.cb_registry_reservations where id=p_gift for update;select * into e from public.cb_registry_entries where id=g.entry_id and project_id=p_project;
 if not found then raise exception 'Gift unavailable' using errcode='42501';end if;
 if g.revision<>p_gift_revision then raise exception 'Gift status changed. Refresh before saving.' using errcode='PT409';end if;
 select * into f from public.cb_registry_followups where gift_id=g.id for update;if coalesce(f.revision,0)<>p_revision then raise exception 'Follow-up changed. Refresh before saving.' using errcode='PT409';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['thanks','message','delivery','room','inventory','notes']::text[]<>'{}' then raise exception 'Review the follow-up details';end if;
 foreach k in array array['thanks','message','delivery','room','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k in ('message','notes') then 2000 else 250 end) then raise exception 'Keep follow-up details within the field limits';end if;end loop;
 if p_data->>'thanks' not in ('To write','Drafted','Sent externally') or p_data->>'room' not in ('Whole home','Kitchen','Bedroom','Living room','Bathroom','Dining room','Storage','Outdoor') or jsonb_typeof(p_data->'inventory') is distinct from 'boolean' then raise exception 'Choose a valid thank-you status and room';end if;
 if p_data->>'thanks' in ('Drafted','Sent externally') and btrim(p_data->>'message')='' then raise exception 'Add the thank-you message first';end if;
 want_inventory=(p_data->>'inventory')::boolean;
 if want_inventory and g.status<>'Received' then raise exception 'Only received gifts can be added to household inventory';end if;
 snapshot=f.inventory_item;
 if want_inventory and snapshot is null then snapshot=jsonb_build_object('title',e.data->>'title','image',e.data->>'image','url',e.data->>'url','quantity',g.quantity);end if;
 insert into public.cb_registry_followups(gift_id,data,inventory_item,updated_by) values(g.id,p_data,snapshot,auth.uid()) on conflict(gift_id) do update set data=excluded.data,inventory_item=excluded.inventory_item,revision=cb_registry_followups.revision+1,updated_by=auth.uid(),updated_at=now() returning * into f;
 result=to_jsonb(f);insert into public.cb_registry_followup_writes values(auth.uid(),p_client,payload,result);insert into public.cb_registry_history(project_id,record_id,actor,action,snapshot) values(p_project,g.id,auth.uid(),'Gift follow-up reviewed',jsonb_build_object('revision',f.revision,'gift_revision',g.revision,'followup',result));return result;
end;$$;
revoke all on function public.cb_registry_followthrough(uuid),public.cb_save_registry_followthrough(uuid,uuid,bigint,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_registry_followthrough(uuid),public.cb_save_registry_followthrough(uuid,uuid,bigint,bigint,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';commit;
