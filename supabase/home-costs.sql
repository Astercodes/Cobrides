-- Household commitments reuse the canonical ledger; no payment or booking is inferred.
-- Run after shared-home.sql and the installed retail-expenses/financial migrations.
begin;
create table if not exists public.cb_home_cost_links(item_id uuid primary key references public.cb_home_items on delete restrict,expense_id uuid not null unique references public.cb_shared_expenses on delete restrict,item_revision bigint not null,revision bigint not null default 1,updated_by uuid not null references auth.users,updated_at timestamptz not null default now());
alter table public.cb_home_cost_links enable row level security;
revoke all on public.cb_home_cost_links from public,anon,authenticated;
create or replace function public.cb_home_costs(p_home uuid,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t public.cb_home_plans;result jsonb;
begin
 if not public.cb_home_access(p_home,false) then raise exception 'Home access required' using errcode='42501';end if;
 select * into t from public.cb_home_plans where id=p_home;
 if not coalesce(public.cb_project_access(t.project_id,'finance'),false) then return jsonb_build_object('home',p_home,'available',false,'can_link',false,'items','[]'::jsonb,'totals','[]'::jsonb,'choices','[]'::jsonb);end if;
 if p_search is null or length(p_search)>100 then raise exception 'Keep expense searches under 100 characters';end if;
 with costs as (
 select l.item_id,l.expense_id,l.revision as link_revision,l.item_revision,e.revision as expense_revision,e.title,e.currency,coalesce(e.settlement_total,e.agreed_total) as commitment,
 coalesce((select sum(case when p.kind='Payment' then p.amount else -p.amount end) from public.cb_shared_payments p where p.expense_id=e.id),0) as net_paid,
 (i.revision<>l.item_revision or i.shopping_id is not null and not exists(select 1 from public.cb_shopping_cost_links sc where sc.item_id=i.shopping_id and sc.expense_id=l.expense_id)) as source_changed,i.data->>'status' as home_status,(select status from public.cb_shopping_items where id=i.shopping_id) as shopping_status
 from public.cb_home_cost_links l join public.cb_home_items i on i.id=l.item_id join public.cb_shared_expenses e on e.id=l.expense_id where i.home_id=p_home and e.project_id=t.project_id
 ),totals as (select currency,count(*) as expenses,sum(commitment) as committed,sum(net_paid) as net_paid,sum(commitment-net_paid) as balance from costs group by currency)
 select jsonb_build_object('home',p_home,'available',true,'can_link',t.owner_id=auth.uid() and not t.archived and public.cb_project_access(t.project_id,'write'),'project',t.project_id,'currency',coalesce((select currency from public.cb_project_finances where project_id=t.project_id),'USD'),
 'items',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('balance',c.commitment-c.net_paid) order by c.title,c.item_id),'[]') from costs c),
 'totals',(select coalesce(jsonb_agg(to_jsonb(c) order by c.currency),'[]') from totals c),
 'required_choices',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select distinct e.id,e.title,e.currency,coalesce(e.settlement_total,e.agreed_total) as total,e.revision from public.cb_home_items i join public.cb_shopping_cost_links sc on sc.item_id=i.shopping_id join public.cb_shared_expenses e on e.id=sc.expense_id where i.home_id=p_home and e.project_id=t.project_id) x),
 'eligibility',(select coalesce(jsonb_agg(jsonb_build_object('item_id',i.id,'kind',case when i.gift_id is not null then 'gift' when i.shopping_id is not null then 'shopping' else 'manual' end,'required_expense',(select expense_id from public.cb_shopping_cost_links where item_id=i.shopping_id))),'[]') from public.cb_home_items i where i.home_id=p_home),
 'choices',(select coalesce(jsonb_agg(to_jsonb(c) order by c.title,c.id),'[]') from (select e.id,e.title,e.currency,coalesce(e.settlement_total,e.agreed_total) as total,e.revision from public.cb_shared_expenses e where e.project_id=t.project_id and not exists(select 1 from public.cb_travel_cost_links x where x.expense_id=e.id) and (p_search='' or e.title ilike '%'||p_search||'%') order by e.title,e.id limit 100) c)) into result;
 return result;
end;$$;
create or replace function public.cb_save_home_cost(p_item uuid,p_item_revision bigint,p_home_revision bigint,p_link_revision bigint,p_client uuid,p_expense uuid,p_expense_revision bigint,p_data jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.cb_home_items;t public.cb_home_plans;l public.cb_home_cost_links;e public.cb_shared_expenses;w public.cb_home_writes;payload jsonb;result jsonb;expense_data jsonb;k text;
begin
 select * into i from public.cb_home_items where id=p_item;select * into t from public.cb_home_plans where id=i.home_id;
 perform 1 from public.cb_projects where id=t.project_id for update;
 select * into t from public.cb_home_plans where id=i.home_id for update;
 if t.id is null or t.owner_id is distinct from auth.uid() or t.archived or not public.cb_home_access(t.id,true) or not coalesce(public.cb_project_access(t.project_id,'finance') and public.cb_project_access(t.project_id,'write'),false) then raise exception 'Home creator and financial editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','home-cost','item',p_item,'item_revision',p_item_revision,'home_revision',p_home_revision,'link_revision',p_link_revision,'expense',p_expense,'expense_revision',p_expense_revision,'data',p_data,'confirm',p_confirm);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same reviewed home cost' using errcode='PT409';end if;return w.response;end if;
 if p_confirm is distinct from true then raise exception 'Confirm the expense fields you want shared with financial collaborators';end if;
 select * into i from public.cb_home_items where id=p_item for update;
 if i.revision is distinct from p_item_revision or t.revision is distinct from p_home_revision then raise exception 'Home details changed. Refresh before connecting a cost.' using errcode='PT409';end if;
 if i.data->>'status'='Cancelled' then raise exception 'Review the cancelled household item before connecting an obligation';end if;
 if i.gift_id is not null then raise exception 'Received gifts do not create household payment obligations';end if;
 if i.shopping_id is not null and (p_expense is null or not exists(select 1 from public.cb_shopping_cost_links where item_id=i.shopping_id and expense_id=p_expense)) then raise exception 'Review this purchase cost in Shopping, then link its existing expense';end if;
 select * into l from public.cb_home_cost_links where item_id=i.id for update;
 if coalesce(l.revision,0) is distinct from p_link_revision then raise exception 'This cost connection changed. Refresh first.' using errcode='PT409';end if;
 if p_expense is null then
 if l.item_id is not null then raise exception 'This household item already has a cost. Open its ledger or select a different existing expense.' using errcode='PT409';end if;
 if p_expense_revision is not null or jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','supplier','currency','total','category']::text[]<>'{}' then raise exception 'Review the home expense fields';end if;
 foreach k in array array['title','supplier','currency','category'] loop if jsonb_typeof(p_data->k) is distinct from 'string' then raise exception 'Review home expense text';end if;end loop;
 expense_data=jsonb_build_object('title',p_data->>'title','merchant',p_data->>'supplier','currency',p_data->>'currency','total',p_data->'total','quantity',1,'productUrl','','orderReference','','purchasedOn','','category',p_data->>'category','note','Reviewed household commitment. Payments are recorded separately.');
 result=public.cb_create_retail_expense(t.project_id,p_client,'home:'||i.id,null,null,expense_data,true);
 select * into e from public.cb_shared_expenses where id=(result->>'id')::uuid;
 else
 if p_data is not null then raise exception 'Choose an existing expense without changing its financial fields';end if;
 select * into e from public.cb_shared_expenses where id=p_expense and project_id=t.project_id for update;
 if e.id is null then raise exception 'Choose an expense from this wedding' using errcode='42501';end if;
 if e.revision is distinct from p_expense_revision then raise exception 'Expense changed. Refresh before linking it.' using errcode='PT409';end if;
 if exists(select 1 from public.cb_travel_cost_links where expense_id=e.id) then raise exception 'This expense is already connected to travel. Choose a household obligation.' using errcode='PT409';end if;
 if exists(select 1 from public.cb_home_cost_links where expense_id=e.id and item_id<>i.id) then raise exception 'This expense is already connected to another household item' using errcode='PT409';end if;
 end if;
 if l.item_id is not null and l.expense_id=e.id and l.item_revision=i.revision then result=to_jsonb(l);insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;end if;
 insert into public.cb_home_cost_links(item_id,expense_id,item_revision,updated_by) values(i.id,e.id,i.revision,auth.uid()) on conflict(item_id) do update set expense_id=excluded.expense_id,item_revision=excluded.item_revision,revision=cb_home_cost_links.revision+1,updated_by=auth.uid(),updated_at=now() returning * into l;
 result=to_jsonb(l);insert into public.cb_home_history values('cost',i.id,l.revision,auth.uid(),result,now());insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
-- Keep the allocation guard symmetric when an existing home expense is reviewed in travel.
do $travel_guard$ declare body text;needle text;begin
 body=pg_get_functiondef('public.cb_save_travel_cost(uuid,bigint,bigint,bigint,uuid,uuid,bigint,jsonb,boolean)'::regprocedure);
 if strpos(body,'public.cb_home_cost_links')=0 then
 needle=' if exists(select 1 from public.cb_travel_cost_links where expense_id=e.id and item_id<>i.id)';
 if strpos(body,needle)=0 then raise exception 'Travel cost linking needs review before home-cost activation';end if;
 body=replace(body,needle,' if exists(select 1 from public.cb_home_cost_links where expense_id=e.id) then raise exception ''This expense is already connected to a household. Choose a travel obligation.'' using errcode=''PT409'';end if;'||chr(10)||needle);execute body;
 end if;end;$travel_guard$;
-- Do not leak home locations, notes or property choices into project activity.
do $activity$ declare body text;begin
 body=pg_get_functiondef('public.cb_create_retail_expense(uuid,uuid,text,uuid,bigint,jsonb,boolean)'::regprocedure);
 if strpos(body,'p_ref like ''home:%''')=0 then
 if strpos(body,'p_ref like ''travel:%''')>0 then body=replace(body,'p_ref like ''travel:%''','(p_ref like ''travel:%'' or p_ref like ''home:%'')');
 else body=replace(body,'''Shared retailer expense reviewed''','case when p_item is null and p_ref like ''home:%'' then ''Shared expense reviewed'' else ''Shared retailer expense reviewed'' end');end if;
 execute body;end if;
end;$activity$;
-- Extend existing presentation without overwriting travel or retailer labels.
do $label$ declare body text;signature text;begin
 foreach signature in array array['public.cb_shared_ledger(uuid)','public.cb_shared_financial_report(uuid)','public.cb_support_allocations(uuid)'] loop
 if to_regprocedure(signature) is not null then body=pg_get_functiondef(to_regprocedure(signature));
 if strpos(body,'public.cb_home_cost_links')=0 then
 if strpos(body,'coalesce(b.status,case when ')>0 then body=replace(body,'coalesce(b.status,case when ','coalesce(b.status,case when e.retail_ref like ''personal:%:home:%'' or exists(select 1 from public.cb_home_cost_links hc where hc.expense_id=e.id) then ''Home commitment'' when ');
 else body=replace(body,'coalesce(b.status,''Retail purchase'')','coalesce(b.status,case when e.retail_ref like ''personal:%:home:%'' or exists(select 1 from public.cb_home_cost_links hc where hc.expense_id=e.id) then ''Home commitment'' else ''Retail purchase'' end)');end if;
 if strpos(body,'public.cb_home_cost_links')=0 then raise exception 'Financial projection needs review before home-cost activation: %',signature;end if;execute body;
 end if;end if;end loop;
end;$label$;
revoke all on function public.cb_home_costs(uuid,text),public.cb_save_home_cost(uuid,bigint,bigint,bigint,uuid,uuid,bigint,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.cb_home_costs(uuid,text),public.cb_save_home_cost(uuid,bigint,bigint,bigint,uuid,uuid,bigint,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';commit;
