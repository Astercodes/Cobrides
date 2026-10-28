-- Shared registry records and reservations. Does not collect or transfer payments.
begin;
create table if not exists public.cb_registry_entries(id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects(id),local_ref text not null,data jsonb not null,revision bigint not null default 1,created_by uuid not null,updated_at timestamptz not null default now(),unique(project_id,local_ref));
create table if not exists public.cb_registry_reservations(id uuid primary key default gen_random_uuid(),entry_id uuid not null references public.cb_registry_entries(id),giver text not null,quantity integer not null,status text not null default 'Reserved',revision bigint not null default 1,created_by uuid not null,updated_at timestamptz not null default now());
create table if not exists public.cb_registry_writes(user_id uuid not null,client uuid not null,request jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_registry_history(id bigint generated always as identity primary key,project_id uuid not null,record_id uuid not null,actor uuid not null,action text not null,snapshot jsonb not null,at timestamptz not null default now());
alter table public.cb_registry_entries enable row level security;alter table public.cb_registry_reservations enable row level security;alter table public.cb_registry_writes enable row level security;alter table public.cb_registry_history enable row level security;
revoke all on public.cb_registry_entries,public.cb_registry_reservations,public.cb_registry_writes,public.cb_registry_history from public,anon,authenticated;
create or replace function public.cb_registry_workspace(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Registry management access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'items',(select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('reserved',(select coalesce(sum(quantity),0) from public.cb_registry_reservations where entry_id=e.id and cb_registry_reservations.status not in ('Cancelled','Returned')),'gifts',(select coalesce(jsonb_agg(to_jsonb(g) order by updated_at desc),'[]') from public.cb_registry_reservations g where entry_id=e.id)) order by e.updated_at desc),'[]') from public.cb_registry_entries e where project_id=p_project));
end;$$;
create or replace function public.cb_write_registry(p_project uuid,p_kind text,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
<<registry_write>>
declare e public.cb_registry_entries;g public.cb_registry_reservations;v jsonb;old public.cb_registry_writes;request jsonb;used integer;qty integer;status text;record_id uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Registry management access required' using errcode='42501';end if;
 if p_client is null or p_revision is null or p_revision<0 or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid registry request';end if;
 request=jsonb_build_object('project',p_project,'kind',p_kind,'id',p_id,'revision',p_revision,'data',p_data);
 select * into old from public.cb_registry_writes where user_id=auth.uid() and client=p_client;
 if found then if old.request is distinct from request then raise exception 'Retry the original request' using errcode='PT409';end if;return old.response;end if;
 if p_kind='item' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('title','url','image','currency','quantity','category','merchant','archived','ref')) then raise exception 'Unsupported registry detail';end if;
  if length(btrim(coalesce(p_data->>'title','')))=0 or length(p_data->>'title')>150 or coalesce(p_data->>'currency','')!~'^[A-Z]{3}$' or coalesce(p_data->>'quantity','')!~'^[0-9]{1,4}$' then raise exception 'Check gift title, currency and quantity';end if;
  qty=(p_data->>'quantity')::integer;if qty<1 or qty>9999 then raise exception 'Invalid quantity';end if;
  if coalesce(p_data->>'url','')!~'^https://[^/@[:space:]]+[^[:space:]]*$' or length(p_data->>'url')>3000 then raise exception 'Use an HTTPS retailer link';end if;
  if coalesce(p_data->>'image','')<>'' and (p_data->>'image'!~'^https://[^/@[:space:]]+[^[:space:]]*$' or length(p_data->>'image')>3000) then raise exception 'Use an HTTPS image';end if;
  if length(coalesce(p_data->>'category',''))>100 or length(coalesce(p_data->>'merchant',''))>100 or length(coalesce(p_data->>'ref',''))>160 or coalesce(p_data->>'archived','false') not in ('true','false') then raise exception 'Invalid gift details';end if;
  if p_id is not null then select * into e from public.cb_registry_entries where id=p_id and project_id=p_project for update;
  else select * into e from public.cb_registry_entries where project_id=p_project and local_ref=p_data->>'ref' for update;end if;
  if found then
   if e.revision<>p_revision then raise exception 'Gift changed. Refresh first.' using errcode='PT409';end if;
   select coalesce(sum(quantity),0) into used from public.cb_registry_reservations where entry_id=e.id and cb_registry_reservations.status not in ('Cancelled','Returned');
   if qty<used then raise exception 'Quantity cannot be below existing reservations';end if;
   update public.cb_registry_entries set data=p_data-'ref',revision=revision+1,updated_at=now() where id=e.id returning to_jsonb(cb_registry_entries) into v;
  else
   if p_id is not null or p_revision<>0 then raise exception 'Gift changed. Refresh first.' using errcode='PT409';end if;
   if (select count(*) from public.cb_registry_entries where project_id=p_project)>=1000 then raise exception 'Registry is full';end if;
   insert into public.cb_registry_entries(project_id,local_ref,data,created_by) values(p_project,coalesce(nullif(p_data->>'ref',''),gen_random_uuid()::text),p_data-'ref',auth.uid()) returning to_jsonb(cb_registry_entries) into v;
  end if;
 elsif p_kind='gift' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('entry','giver','quantity','status')) then raise exception 'Unsupported gift detail';end if;
  if coalesce(p_data->>'quantity','')!~'^[0-9]{1,4}$' or length(btrim(coalesce(p_data->>'giver','')))=0 or length(p_data->>'giver')>160 then raise exception 'Check giver and quantity';end if;
  qty=(p_data->>'quantity')::integer;status=p_data->>'status';if qty<1 or status not in ('Reserved','Purchased externally','Shipped','Received','Cancelled','Returned') or status is null then raise exception 'Invalid gift status or quantity';end if;
  select * into e from public.cb_registry_entries where id=(p_data->>'entry')::uuid and project_id=p_project for update;if not found then raise exception 'Gift not found';end if;
  if p_id is not null then
   select * into g from public.cb_registry_reservations where id=p_id and entry_id=e.id for update;
   if not found or g.revision<>p_revision then raise exception 'Reservation changed. Refresh first.' using errcode='PT409';end if;
   if g.quantity<>qty then raise exception 'Cancel and create another reservation to change its quantity';end if;
   if not (g.status='Reserved' and status in ('Purchased externally','Received','Cancelled') or g.status='Purchased externally' and status in ('Shipped','Received','Cancelled') or g.status='Shipped' and status in ('Received','Cancelled') or g.status='Received' and status='Returned') then raise exception 'Invalid delivery transition';end if;
  elsif p_revision<>0 or status<>'Reserved' then raise exception 'New gifts start as Reserved';end if;
  select coalesce(sum(quantity),0) into used from public.cb_registry_reservations where entry_id=e.id and id is distinct from p_id and cb_registry_reservations.status not in ('Cancelled','Returned');
  if status not in ('Cancelled','Returned') and ((p_id is null and coalesce((e.data->>'archived')::boolean,false)) or used+qty>(e.data->>'quantity')::integer) then raise exception 'This gift is archived or no longer has enough remaining quantity';end if;
  if p_id is null then insert into public.cb_registry_reservations(entry_id,giver,quantity,status,created_by) values(e.id,btrim(p_data->>'giver'),qty,status,auth.uid()) returning to_jsonb(cb_registry_reservations) into v;
  else update public.cb_registry_reservations set status=registry_write.status,giver=btrim(p_data->>'giver'),revision=revision+1,updated_at=now() where id=g.id returning to_jsonb(cb_registry_reservations) into v;end if;
 else raise exception 'Unknown registry action';end if;
 record_id=(v->>'id')::uuid;insert into public.cb_registry_history(project_id,record_id,actor,action,snapshot) values(p_project,record_id,auth.uid(),p_kind,v);
 insert into public.cb_registry_writes values(auth.uid(),p_client,request,v);return v;
end;$$;
revoke all on function public.cb_registry_workspace(uuid),public.cb_write_registry(uuid,text,uuid,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_registry_workspace(uuid),public.cb_write_registry(uuid,text,uuid,bigint,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
