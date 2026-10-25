-- Shared quotations and confirmed booking records; no funds are moved.
begin;
create table if not exists public.cb_vendor_quotes(
 id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.cb_shared_vendors on delete cascade,
 title text not null,scope text not null default '',currency text not null,subtotal numeric(18,2) not null,tax_rate numeric(7,4) not null default 0,service_rate numeric(7,4) not null default 0,delivery numeric(18,2) not null default 0,total numeric(18,2) not null,
 valid_until date,service_date date,event_id uuid references public.cb_project_events on delete set null,terms text not null default '',status text not null default 'Received',revision bigint not null default 1,created_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_vendor_bookings(
 id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.cb_shared_vendors on delete cascade,quote_id uuid not null unique references public.cb_vendor_quotes,
 quote_revision bigint not null,quote_snapshot jsonb not null,title text not null,scope text not null default '',service_date date,event_id uuid references public.cb_project_events on delete set null,
 status text not null default 'Confirmed' check(status in ('Confirmed','Completed','Cancelled')),milestones jsonb not null default '[]',revision bigint not null default 1,created_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_vendor_commercial_writes(user_id uuid not null references auth.users,client_id uuid not null,project_id uuid not null references public.cb_projects on delete cascade,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_vendor_commercial_versions(kind text not null,target_id uuid not null,project_id uuid not null references public.cb_projects on delete cascade,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(kind,target_id,revision));
alter table public.cb_vendor_commercial_versions enable row level security;
revoke all on public.cb_vendor_commercial_versions from public,anon,authenticated;
alter table public.cb_vendor_quotes enable row level security;
alter table public.cb_vendor_bookings enable row level security;
alter table public.cb_vendor_commercial_writes enable row level security;
revoke all on public.cb_vendor_quotes,public.cb_vendor_bookings,public.cb_vendor_commercial_writes from public,anon,authenticated;
create index if not exists cb_vendor_quotes_vendor on public.cb_vendor_quotes(vendor_id,created_at desc);
create index if not exists cb_vendor_bookings_vendor on public.cb_vendor_bookings(vendor_id,created_at desc);
create or replace function public.cb_vendor_finance_access(p_vendor uuid) returns boolean language sql stable security definer set search_path='' as $$select public.cb_shared_vendor_access(p_vendor) and exists(select 1 from public.cb_shared_vendors v where v.id=p_vendor and public.cb_project_access(v.project_id,'finance'))$$;
create or replace function public.cb_vendor_commercial(p_vendor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;financial boolean;editable boolean;
begin
 if not public.cb_shared_vendor_access(p_vendor) then raise exception 'Vendor access denied' using errcode='42501';end if;
 select project_id into pid from public.cb_shared_vendors where id=p_vendor;financial=public.cb_vendor_finance_access(p_vendor);editable=financial and public.cb_project_access(pid,'write') and not exists(select 1 from public.cb_shared_vendors where id=p_vendor and archived);
 return jsonb_build_object('vendor',(select name from public.cb_shared_vendors where id=p_vendor),'project',pid,'finance',financial,'editable',editable,
 'events',case when editable then (select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title)),'[]') from public.cb_project_events where project_id=pid and public.cb_project_event_access(id)) else '[]'::jsonb end,
 'quotes',case when financial then (select coalesce(jsonb_agg(to_jsonb(q)||jsonb_build_object('has_booking',exists(select 1 from public.cb_vendor_bookings b where b.quote_id=q.id),'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'at',at) order by revision desc),'[]') from public.cb_vendor_commercial_versions where kind='quote' and target_id=q.id)) order by q.created_at desc),'[]') from public.cb_vendor_quotes q where vendor_id=p_vendor) else '[]'::jsonb end,
 'bookings',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'title',b.title,'scope',b.scope,'service_date',b.service_date,'event_id',case when public.cb_project_event_access(b.event_id) then b.event_id else null end,'status',b.status,'revision',b.revision)||case when financial then jsonb_build_object('quote_id',b.quote_id,'quote_revision',b.quote_revision,'quote_snapshot',b.quote_snapshot,'milestones',b.milestones,'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'at',at) order by revision desc),'[]') from public.cb_vendor_commercial_versions where kind='booking' and target_id=b.id)) else '{}'::jsonb end order by b.created_at desc),'[]') from public.cb_vendor_bookings b where b.vendor_id=p_vendor));
end; $$;
create or replace function public.cb_save_vendor_quote(p_vendor uuid,p_id uuid,p_client uuid,p_revision bigint,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;q public.cb_vendor_quotes;payload jsonb;previous public.cb_vendor_commercial_writes;result jsonb;amount numeric;tax numeric;service numeric;shipping numeric;agreed_total numeric;eventid uuid;k text;
begin
 select project_id into pid from public.cb_shared_vendors where id=p_vendor;perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_vendor_finance_access(p_vendor) or not public.cb_project_access(pid,'write') or exists(select 1 from public.cb_shared_vendors where id=p_vendor and archived) then raise exception 'Quotation editing requires planning and financial access' using errcode='42501';end if;
 payload=jsonb_build_object('kind','quote','vendor',p_vendor,'id',p_id,'revision',p_revision,'data',p_data);
 if p_client is null then raise exception 'A save request ID is required';end if;
 select * into previous from public.cb_vendor_commercial_writes where user_id=auth.uid() and client_id=p_client;
 if found then if previous.payload is distinct from payload then raise exception 'Quotation changed during retry' using errcode='PT409';end if;return previous.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>14000 or p_data-array['title','scope','currency','amount','tax','service','delivery','validUntil','serviceDate','eventId','terms','status']::text[]<>'{}' then raise exception 'Enter valid quotation fields';end if;
 foreach k in array array['title','scope','currency','terms','status'] loop if p_data ? k and jsonb_typeof(p_data->k)<>'string' then raise exception 'Quotation text fields must be text';end if;end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 200 or length(coalesce(p_data->>'scope',''))>4000 or length(coalesce(p_data->>'terms',''))>4000 or coalesce(p_data->>'currency','') !~ '^[A-Z]{3}$' or coalesce(p_data->>'status','Received') not in ('Draft','Received','Negotiating','Declined') then raise exception 'Check the quotation name, currency and status';end if;
 foreach k in array array['amount','tax','service','delivery'] loop if jsonb_typeof(p_data->k) is distinct from 'number' or (p_data->>k)::numeric<0 or (p_data->>k)::numeric>1000000000000 then raise exception 'Use non-negative quotation amounts';end if;end loop;
 amount=(p_data->>'amount')::numeric;tax=(p_data->>'tax')::numeric;service=(p_data->>'service')::numeric;shipping=(p_data->>'delivery')::numeric;
 if tax>100 or service>100 or tax<>round(tax,4) or service<>round(service,4) or amount<>round(amount,2) or shipping<>round(shipping,2) then raise exception 'Use rates up to 100 percent and prices with at most two decimals';end if;
 agreed_total=round(amount*(1+(tax+service)/100)+shipping,2);if agreed_total>1000000000000 then raise exception 'Quotation total is too large';end if;
 if exists(select 1 from jsonb_each(p_data) where key in ('validUntil','serviceDate') and value<>'null'::jsonb and (jsonb_typeof(value)<>'string' or ((value#>>'{}')<>'' and (value#>>'{}') !~ '^\d{4}-\d{2}-\d{2}$'))) then raise exception 'Use dates in YYYY-MM-DD format';end if;
 eventid=nullif(p_data->>'eventId','')::uuid;if eventid is not null and not exists(select 1 from public.cb_project_events where id=eventid and project_id=pid and public.cb_project_event_access(id)) then raise exception 'Choose an accessible celebration in this wedding';end if;
 if p_id is null then
  if p_revision<>0 then raise exception 'Use a new quotation revision';end if;
  insert into public.cb_vendor_quotes(vendor_id,title,scope,currency,subtotal,tax_rate,service_rate,delivery,total,valid_until,service_date,event_id,terms,status,created_by) values(p_vendor,btrim(p_data->>'title'),coalesce(p_data->>'scope',''),p_data->>'currency',amount,tax,service,shipping,agreed_total,nullif(p_data->>'validUntil','')::date,nullif(p_data->>'serviceDate','')::date,eventid,coalesce(p_data->>'terms',''),coalesce(p_data->>'status','Received'),auth.uid()) returning * into q;
 else
  if exists(select 1 from public.cb_vendor_bookings where quote_id=p_id) then raise exception 'This quotation is preserved with its booking. Create a new quotation for revised terms.';end if;
  update public.cb_vendor_quotes set title=btrim(p_data->>'title'),scope=coalesce(p_data->>'scope',''),currency=p_data->>'currency',subtotal=amount,tax_rate=tax,service_rate=service,delivery=shipping,total=agreed_total,valid_until=nullif(p_data->>'validUntil','')::date,service_date=nullif(p_data->>'serviceDate','')::date,event_id=eventid,terms=coalesce(p_data->>'terms',''),status=coalesce(p_data->>'status','Received'),revision=revision+1,updated_at=now() where id=p_id and vendor_id=p_vendor and revision=p_revision returning * into q;
  if not found then raise exception 'Quotation changed. Reload before saving.' using errcode='PT409';end if;
 end if;
 result=to_jsonb(q);insert into public.cb_vendor_commercial_versions values('quote',q.id,pid,q.revision,auth.uid(),result,now());insert into public.cb_vendor_commercial_writes values(auth.uid(),p_client,pid,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Vendor quotation saved',array['vendor']);return result;
end; $$;
create or replace function public.cb_save_vendor_booking(p_vendor uuid,p_id uuid,p_quote uuid,p_quote_revision bigint,p_client uuid,p_revision bigint,p_data jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;q public.cb_vendor_quotes;b public.cb_vendor_bookings;previous public.cb_vendor_commercial_writes;payload jsonb;result jsonb;plan jsonb;part jsonb;sum_amount numeric:=0;target_total numeric;eventid uuid;
begin
 select project_id into pid from public.cb_shared_vendors where id=p_vendor;perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_vendor_finance_access(p_vendor) or not public.cb_project_access(pid,'write') or exists(select 1 from public.cb_shared_vendors where id=p_vendor and archived) then raise exception 'Booking editing requires planning and financial access' using errcode='42501';end if;
 if p_confirm is distinct from true then raise exception 'Confirm these are agreed booking details';end if;
 if p_client is null then raise exception 'A save request ID is required';end if;
 payload=jsonb_build_object('kind','booking','vendor',p_vendor,'id',p_id,'quote',p_quote,'quote_revision',p_quote_revision,'revision',p_revision,'data',p_data);
 select * into previous from public.cb_vendor_commercial_writes where user_id=auth.uid() and client_id=p_client;
 if found then if previous.payload is distinct from payload then raise exception 'Booking changed during retry' using errcode='PT409';end if;return previous.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>14000 or p_data-array['title','scope','serviceDate','eventId','status','milestones']::text[]<>'{}' or length(btrim(coalesce(p_data->>'title',''))) not between 1 and 200 or length(coalesce(p_data->>'scope',''))>4000 or coalesce(p_data->>'status','Confirmed') not in ('Confirmed','Completed','Cancelled') then raise exception 'Enter valid booking details';end if;
 if exists(select 1 from jsonb_each(p_data) where key in ('title','scope','serviceDate','eventId','status') and jsonb_typeof(value)<>'string') then raise exception 'Booking text fields must be text';end if;
 select * into q from public.cb_vendor_quotes where id=p_quote and vendor_id=p_vendor;
 if not found or q.revision is distinct from p_quote_revision then raise exception 'Quotation changed. Review it before confirming.' using errcode='PT409';end if;
 select * into b from public.cb_vendor_bookings where id=p_id and vendor_id=p_vendor;
 if p_id is null then
  if p_revision<>0 or q.status in ('Draft','Declined') or q.valid_until<current_date or coalesce(p_data->>'status','Confirmed')<>'Confirmed' then raise exception 'Use a current received quotation to record a confirmed booking';end if;
  if exists(select 1 from public.cb_vendor_bookings where quote_id=p_quote) then raise exception 'This quotation already has a booking. Open its existing record.' using errcode='PT409';end if;
 else
  if b.id is null or b.revision is distinct from p_revision or b.quote_id is distinct from p_quote then raise exception 'Booking changed. Reload before saving.' using errcode='PT409';end if;
  if b.status='Cancelled' then raise exception 'Cancelled bookings are preserved. Record a new agreement separately.';end if;
 end if;
 target_total=case when p_id is null then q.total else (b.quote_snapshot->>'total')::numeric end;
 plan=coalesce(p_data->'milestones','[]');if jsonb_typeof(plan)<>'array' or jsonb_array_length(plan)>12 then raise exception 'Use up to twelve payment milestones';end if;
 for part in select jsonb_array_elements(plan) loop
  if jsonb_typeof(part)<>'object' or part-array['id','title','amount','due']::text[]<>'{}' or coalesce(part->>'id','') !~ '^[A-Za-z0-9_-]{1,80}$' or length(btrim(coalesce(part->>'title',''))) not between 1 and 120 or jsonb_typeof(part->'amount') is distinct from 'number' or (part->>'amount')::numeric<=0 or (part->>'amount')::numeric<>round((part->>'amount')::numeric,2) or coalesce(part->>'due','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Give every payment milestone a name, positive amount and valid due date';end if;
  perform (part->>'due')::date;sum_amount=sum_amount+(part->>'amount')::numeric;
 end loop;
 if (select count(distinct x->>'id') from jsonb_array_elements(plan) x)<>jsonb_array_length(plan) or (jsonb_array_length(plan)>0 and sum_amount<>target_total) then raise exception 'Payment milestones must be unique and total the agreed quotation';end if;
 eventid=nullif(p_data->>'eventId','')::uuid;if eventid is not null and not exists(select 1 from public.cb_project_events where id=eventid and project_id=pid and public.cb_project_event_access(id)) then raise exception 'Choose an accessible celebration in this wedding';end if;
 if p_id is null then
  insert into public.cb_vendor_bookings(vendor_id,quote_id,quote_revision,quote_snapshot,title,scope,service_date,event_id,status,milestones,created_by) values(p_vendor,q.id,q.revision,to_jsonb(q),btrim(p_data->>'title'),coalesce(p_data->>'scope',''),nullif(p_data->>'serviceDate','')::date,eventid,'Confirmed',plan,auth.uid()) returning * into b;
 else
  update public.cb_vendor_bookings set title=btrim(p_data->>'title'),scope=coalesce(p_data->>'scope',''),service_date=nullif(p_data->>'serviceDate','')::date,event_id=eventid,status=coalesce(p_data->>'status','Confirmed'),milestones=plan,revision=revision+1,updated_at=now() where id=b.id returning * into b;
 end if;
 result=to_jsonb(b);insert into public.cb_vendor_commercial_versions values('booking',b.id,pid,b.revision,auth.uid(),result,now());insert into public.cb_vendor_commercial_writes values(auth.uid(),p_client,pid,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Vendor booking record updated',array['vendor']);return result;
end; $$;
revoke all on function public.cb_vendor_finance_access(uuid),public.cb_vendor_commercial(uuid),public.cb_save_vendor_quote(uuid,uuid,uuid,bigint,jsonb),public.cb_save_vendor_booking(uuid,uuid,uuid,bigint,uuid,bigint,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.cb_vendor_commercial(uuid),public.cb_save_vendor_quote(uuid,uuid,uuid,bigint,jsonb),public.cb_save_vendor_booking(uuid,uuid,uuid,bigint,uuid,bigint,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
