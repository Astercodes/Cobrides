-- Standalone retailer commitments use the same protected ledger and payment journal.
begin;
alter table public.cb_shared_expenses alter column booking_id drop not null;
alter table public.cb_shared_expenses alter column booking_revision drop not null;
alter table public.cb_shared_expenses add column if not exists retail_ref text;
alter table public.cb_shared_expenses add column if not exists retail_details jsonb;
create unique index if not exists cb_retail_expense_source on public.cb_shared_expenses(project_id,retail_ref) where retail_ref is not null;
do $$begin
 if not exists(select 1 from pg_constraint where conrelid='public.cb_shared_expenses'::regclass and conname='cb_expense_source_valid') then
 alter table public.cb_shared_expenses add constraint cb_expense_source_valid check(
 (booking_id is not null and booking_revision is not null and retail_ref is null and retail_details is null) or
 (booking_id is null and booking_revision is null and retail_ref is not null and retail_details is not null and length(retail_ref) between 1 and 400 and jsonb_typeof(retail_details)='object'));
 end if;
end;$$;
-- Preserve installed schedule/history/notification behavior while broadening read projections.
do $patch$
declare signature text;body text;
begin
 foreach signature in array array['public.cb_shared_ledger(uuid)','public.cb_shared_financial_report(uuid)','public.cb_expense_deadlines(uuid)','public.cb_support_allocations(uuid)'] loop
 if to_regprocedure(signature) is null then raise exception 'Apply the existing shared finance migrations before retail-expenses.sql: %',signature;end if;
 body=pg_get_functiondef(to_regprocedure(signature));
 body=replace(body,'e join public.cb_vendor_bookings b on b.id=e.booking_id','e left join public.cb_vendor_bookings b on b.id=e.booking_id');
 body=replace(body,'join public.cb_shared_vendors v on v.id=b.vendor_id','left join public.cb_shared_vendors v on v.id=b.vendor_id');
 body=replace(body,'''booking_status'',b.status','''booking_status'',coalesce(b.status,''Retail purchase'')');
 body=replace(body,'''vendor'',v.name','''vendor'',coalesce(v.name,e.retail_details->>''merchant'')');
 body=replace(body,'v.name as vendor','coalesce(v.name,e.retail_details->>''merchant'') as vendor');
 body=replace(body,'coalesce(v.details->>''category'',''Other'') as category','coalesce(v.details->>''category'',e.retail_details->>''category'',''Other'') as category');
 body=replace(body,'b.status as booking_status','coalesce(b.status,''Retail purchase'') as booking_status');
 body=replace(body,'and b.status<>''Cancelled''','and coalesce(b.status,''Confirmed'')<>''Cancelled''');
 -- Reapplying this migration must not produce LEFT LEFT JOINs.
 body=replace(body,'left left join','left join');
 if strpos(body,'e left join public.cb_vendor_bookings b on b.id=e.booking_id')=0 then raise exception 'Unrecognized installed financial projection: %',signature;end if;
 execute body;
 end loop;
end;$patch$;
create or replace function public.cb_retail_expense_sources(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'read') and public.cb_project_access(p_project,'finance'),false) then raise exception 'Financial access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'editable',public.cb_project_access(p_project,'write'),'currency',coalesce((select currency from public.cb_project_finances where project_id=p_project),'USD'),
 'items',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'ref',retail_ref,'title',title,'currency',currency,'total',coalesce(settlement_total,agreed_total))),'[]') from public.cb_shared_expenses where project_id=p_project and retail_ref is not null));
end;$$;
create or replace function public.cb_create_retail_expense(p_project uuid,p_client uuid,p_ref text,p_item uuid,p_item_revision bigint,p_data jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_shared_expenses;prev public.cb_shared_ledger_writes;payload jsonb;result jsonb;ref text;total numeric;k text;v text;item public.cb_shopping_items;l public.cb_shopping_lists;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'read') and public.cb_project_access(p_project,'finance') and public.cb_project_access(p_project,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 if p_item is not null then
 select * into item from public.cb_shopping_items where id=p_item;select * into l from public.cb_shopping_lists where id=item.list_id;
 if not coalesce(l.project_id=p_project and public.cb_shopping_access(l.id) and not l.archived,false) then raise exception 'Shopping item access required' using errcode='42501';end if;
 ref='team:'||p_item::text;
 else
 if length(coalesce(p_ref,'')) not between 1 and 250 then raise exception 'A purchase reference is required';end if;
 ref='personal:'||auth.uid()::text||':'||p_ref;
 end if;
 payload=jsonb_build_object('kind','retail-expense','project',p_project,'ref',p_ref,'item',p_item,'item_revision',p_item_revision,'data',p_data,'confirm',p_confirm);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_shared_ledger_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if p_confirm is distinct from true then raise exception 'Review and confirm this retailer commitment';end if;
 if p_item is not null and (item.revision is distinct from p_item_revision) then raise exception 'Shopping item changed. Refresh before connecting.' using errcode='PT409';end if;
 if exists(select 1 from public.cb_shared_expenses where project_id=p_project and retail_ref=ref) or (p_item is not null and exists(select 1 from public.cb_shopping_cost_links where item_id=p_item)) then raise exception 'This purchase already has a shared expense. Open the existing record.' using errcode='PT409';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>10000 or p_data-array['title','merchant','currency','total','quantity','productUrl','orderReference','purchasedOn','category','note']::text[]<>'{}' then raise exception 'Check retailer expense fields';end if;
 for k,v in select key,value #>> '{}' from jsonb_each(p_data) where key not in ('total','quantity') loop
 if jsonb_typeof(p_data->k)<>'string' or length(v)>(case when k in ('note','productUrl') then 2000 else 200 end) then raise exception 'Expense text fields exceed their limits';end if;
 end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 200 or length(btrim(coalesce(p_data->>'merchant',''))) not between 1 and 160 or (coalesce(p_data->>'currency','') !~ '^[A-Z]{3}$' or p_data->>'currency' in ('XXX','XTS')) then raise exception 'Enter the item, retailer and original purchase currency';end if;
 if jsonb_typeof(p_data->'total') is distinct from 'number' or jsonb_typeof(p_data->'quantity') is distinct from 'number' then raise exception 'Enter a numeric total and quantity';end if;
 total=(p_data->>'total')::numeric;
 if total<=0 or total>1000000000000 or total<>round(total,2) or (p_data->>'quantity')::numeric not between 1 and 9999 or (p_data->>'quantity')::numeric<>trunc((p_data->>'quantity')::numeric) then raise exception 'Use a positive total with two decimals and a whole quantity';end if;
 if coalesce(p_data->>'category','') not in ('venue','catering','photo','fashion','decor','music','transport','stationery','other') then raise exception 'Choose a budget category';end if;
 v=coalesce(p_data->>'productUrl','');if v<>'' and (v !~ '^https://[^/?#[:space:]]+([/?#]|$)' or v ~ '^https://[^/]*@' or v ~ '[[:space:]]') then raise exception 'Use a secure product link without login details';end if;
 v=coalesce(p_data->>'purchasedOn','');if v<>'' then if v !~ '^\d{4}-\d{2}-\d{2}$' or v::date>current_date then raise exception 'Use an actual purchase date no later than today';end if;end if;
 insert into public.cb_shared_expenses(project_id,booking_id,title,currency,agreed_total,schedule,booking_revision,created_by,retail_ref,retail_details,schedule_total)
 values(p_project,null,btrim(p_data->>'title'),p_data->>'currency',total,'[]',null,auth.uid(),ref,p_data-'total'-'title'-'currency',total) returning * into e;
 insert into public.cb_budget_categories(expense_id,category,updated_by) values(e.id,p_data->>'category',auth.uid());
 if p_item is not null then
 insert into public.cb_shopping_cost_links values(p_item,e.id,1);
 update public.cb_shopping_items set revision=revision+1,updated_at=now() where id=p_item returning * into item;
 insert into public.cb_shopping_versions values('item',p_item,item.revision,auth.uid(),to_jsonb(item),now());
 insert into public.cb_shopping_versions values('cost',p_item,1,auth.uid(),jsonb_build_object('item_id',p_item,'expense_id',e.id,'revision',1),now());
 end if;
 insert into public.cb_shared_ledger_versions values(e.id,e.revision,auth.uid(),to_jsonb(e),now());result=to_jsonb(e);
 insert into public.cb_shared_ledger_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared retailer expense reviewed',array['finance']);return result;
end;$$;
revoke all on function public.cb_retail_expense_sources(uuid),public.cb_create_retail_expense(uuid,uuid,text,uuid,bigint,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.cb_retail_expense_sources(uuid),public.cb_create_retail_expense(uuid,uuid,text,uuid,bigint,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
