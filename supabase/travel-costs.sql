-- Honeymoon commitments reuse the canonical ledger; no payment or booking is inferred.
-- Run after shared-travel.sql and the installed retail-expenses/financial migrations.
begin;
create table if not exists public.cb_travel_cost_links(item_id uuid primary key references public.cb_travel_items on delete restrict,expense_id uuid not null unique references public.cb_shared_expenses on delete restrict,item_revision bigint not null,revision bigint not null default 1,updated_by uuid not null references auth.users,updated_at timestamptz not null default now());
alter table public.cb_travel_cost_links enable row level security;
revoke all on public.cb_travel_cost_links from public,anon,authenticated;
create or replace function public.cb_travel_costs(p_trip uuid,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t public.cb_travel_plans;result jsonb;
begin
 if not public.cb_travel_access(p_trip,false) then raise exception 'Trip access required' using errcode='42501';end if;
 select * into t from public.cb_travel_plans where id=p_trip;
 if not coalesce(public.cb_project_access(t.project_id,'finance'),false) then return jsonb_build_object('trip',p_trip,'available',false,'can_link',false,'items','[]'::jsonb,'totals','[]'::jsonb,'choices','[]'::jsonb);end if;
 if p_search is null or length(p_search)>100 then raise exception 'Keep expense searches under 100 characters';end if;
 with costs as (
 select l.item_id,l.expense_id,l.revision as link_revision,l.item_revision,e.revision as expense_revision,e.title,e.currency,coalesce(e.settlement_total,e.agreed_total) as commitment,
 coalesce((select sum(case when p.kind='Payment' then p.amount else -p.amount end) from public.cb_shared_payments p where p.expense_id=e.id),0) as net_paid,
 i.revision<>l.item_revision as source_changed,i.data->>'status' as travel_status
 from public.cb_travel_cost_links l join public.cb_travel_items i on i.id=l.item_id join public.cb_shared_expenses e on e.id=l.expense_id where i.trip_id=p_trip and e.project_id=t.project_id
 ),totals as (select currency,count(*) as expenses,sum(commitment) as committed,sum(net_paid) as net_paid,sum(commitment-net_paid) as balance from costs group by currency)
 select jsonb_build_object('trip',p_trip,'available',true,'can_link',t.owner_id=auth.uid() and not t.archived and public.cb_project_access(t.project_id,'write'),'project',t.project_id,'currency',coalesce((select currency from public.cb_project_finances where project_id=t.project_id),'USD'),
 'items',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('balance',c.commitment-c.net_paid) order by c.title,c.item_id),'[]') from costs c),
 'totals',(select coalesce(jsonb_agg(to_jsonb(c) order by c.currency),'[]') from totals c),
 'choices',(select coalesce(jsonb_agg(to_jsonb(c) order by c.title,c.id),'[]') from (select e.id,e.title,e.currency,coalesce(e.settlement_total,e.agreed_total) as total,e.revision from public.cb_shared_expenses e where e.project_id=t.project_id and (p_search='' or e.title ilike '%'||p_search||'%') order by e.title,e.id limit 100) c)) into result;
 return result;
end;$$;
create or replace function public.cb_save_travel_cost(p_item uuid,p_item_revision bigint,p_trip_revision bigint,p_link_revision bigint,p_client uuid,p_expense uuid,p_expense_revision bigint,p_data jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.cb_travel_items;t public.cb_travel_plans;l public.cb_travel_cost_links;e public.cb_shared_expenses;w public.cb_travel_writes;payload jsonb;result jsonb;expense_data jsonb;k text;
begin
 select * into i from public.cb_travel_items where id=p_item;select * into t from public.cb_travel_plans where id=i.trip_id;
 perform 1 from public.cb_projects where id=t.project_id for update;
 select * into t from public.cb_travel_plans where id=i.trip_id for update;
 if t.id is null or t.owner_id is distinct from auth.uid() or t.archived or not public.cb_travel_access(t.id,true) or not coalesce(public.cb_project_access(t.project_id,'finance') and public.cb_project_access(t.project_id,'write'),false) then raise exception 'Trip creator and financial editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','travel-cost','item',p_item,'item_revision',p_item_revision,'trip_revision',p_trip_revision,'link_revision',p_link_revision,'expense',p_expense,'expense_revision',p_expense_revision,'data',p_data,'confirm',p_confirm);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_travel_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same reviewed travel cost' using errcode='PT409';end if;return w.response;end if;
 if p_confirm is distinct from true then raise exception 'Confirm the expense fields you want shared with financial collaborators';end if;
 select * into i from public.cb_travel_items where id=p_item for update;
 if i.revision is distinct from p_item_revision or t.revision is distinct from p_trip_revision then raise exception 'Travel details changed. Refresh before connecting a cost.' using errcode='PT409';end if;
 if i.data->>'status' not in ('Booked externally','Confirmed externally','Complete') then raise exception 'Record a confirmed reservation or completed activity before adding an obligation';end if;
 select * into l from public.cb_travel_cost_links where item_id=i.id for update;
 if coalesce(l.revision,0) is distinct from p_link_revision then raise exception 'This cost connection changed. Refresh first.' using errcode='PT409';end if;
 if p_expense is null then
 if l.item_id is not null then raise exception 'This activity already has a cost. Open its ledger or select a different existing expense.' using errcode='PT409';end if;
 if p_expense_revision is not null or jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','supplier','currency','total','category']::text[]<>'{}' then raise exception 'Review the travel expense fields';end if;
 foreach k in array array['title','supplier','currency','category'] loop if jsonb_typeof(p_data->k) is distinct from 'string' then raise exception 'Review travel expense text';end if;end loop;
 expense_data=jsonb_build_object('title',p_data->>'title','merchant',p_data->>'supplier','currency',p_data->>'currency','total',p_data->'total','quantity',1,'productUrl','','orderReference','','purchasedOn','','category',p_data->>'category','note','Reviewed travel commitment. Payments are recorded separately.');
 result=public.cb_create_retail_expense(t.project_id,p_client,'travel:'||i.id,null,null,expense_data,true);
 select * into e from public.cb_shared_expenses where id=(result->>'id')::uuid;
 else
 if p_data is not null then raise exception 'Choose an existing expense without changing its financial fields';end if;
 select * into e from public.cb_shared_expenses where id=p_expense and project_id=t.project_id for update;
 if e.id is null then raise exception 'Choose an expense from this wedding' using errcode='42501';end if;
 if e.revision is distinct from p_expense_revision then raise exception 'Expense changed. Refresh before linking it.' using errcode='PT409';end if;
 if exists(select 1 from public.cb_travel_cost_links where expense_id=e.id and item_id<>i.id) then raise exception 'This expense is already connected to another travel activity' using errcode='PT409';end if;
 end if;
 if l.item_id is not null and l.expense_id=e.id and l.item_revision=i.revision then result=to_jsonb(l);insert into public.cb_travel_writes values(auth.uid(),p_client,payload,result);return result;end if;
 insert into public.cb_travel_cost_links(item_id,expense_id,item_revision,updated_by) values(i.id,e.id,i.revision,auth.uid()) on conflict(item_id) do update set expense_id=excluded.expense_id,item_revision=excluded.item_revision,revision=cb_travel_cost_links.revision+1,updated_by=auth.uid(),updated_at=now() returning * into l;
 result=to_jsonb(l);insert into public.cb_travel_history values('cost',i.id,l.revision,auth.uid(),result,now());insert into public.cb_travel_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
-- The shared activity feed gets a generic expense action, never itinerary details.
do $activity$ declare body text;begin body=pg_get_functiondef('public.cb_create_retail_expense(uuid,uuid,text,uuid,bigint,jsonb,boolean)'::regprocedure);if strpos(body,'''Shared expense reviewed''')=0 then body=replace(body,'''Shared retailer expense reviewed''','case when p_item is null and p_ref like ''travel:%'' then ''Shared expense reviewed'' else ''Shared retailer expense reviewed'' end');execute body;end if;end;$activity$;
-- Keep the ledger's presentation accurate without modifying its agreements or journals.
do $label$ declare body text;signature text;begin foreach signature in array array['public.cb_shared_ledger(uuid)','public.cb_shared_financial_report(uuid)','public.cb_expense_deadlines(uuid)','public.cb_support_allocations(uuid)'] loop if to_regprocedure(signature) is not null then body=pg_get_functiondef(to_regprocedure(signature));if strpos(body,'public.cb_travel_cost_links')=0 then body=replace(body,'coalesce(b.status,''Retail purchase'')','coalesce(b.status,case when e.retail_ref like ''personal:%:travel:%'' or exists(select 1 from public.cb_travel_cost_links tc where tc.expense_id=e.id) then ''Travel commitment'' else ''Retail purchase'' end)');execute body;end if;end if;end loop;end;$label$;
revoke all on function public.cb_travel_costs(uuid,text),public.cb_save_travel_cost(uuid,bigint,bigint,bigint,uuid,uuid,bigint,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.cb_travel_costs(uuid,text),public.cb_save_travel_cost(uuid,bigint,bigint,bigint,uuid,uuid,bigint,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';commit;
