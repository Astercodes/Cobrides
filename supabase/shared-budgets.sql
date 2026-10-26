-- Native-currency shared budgets. Forecasts use commitments + reviewed unbooked estimates + reserve.
begin;
create table if not exists public.cb_shared_budgets(project_id uuid not null references public.cb_projects on delete cascade,currency text not null,target numeric(18,2) not null,reserve numeric(18,2) not null,plan jsonb not null,revision bigint not null default 1,updated_by uuid not null references auth.users,updated_at timestamptz not null default now(),primary key(project_id,currency));
create table if not exists public.cb_budget_categories(expense_id uuid primary key references public.cb_shared_expenses on delete cascade,category text not null,revision bigint not null default 1,updated_by uuid not null references auth.users);
create table if not exists public.cb_budget_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_budget_versions(project_id uuid not null references public.cb_projects on delete cascade,currency text not null,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(project_id,currency,revision));
alter table public.cb_shared_budgets enable row level security;alter table public.cb_budget_categories enable row level security;alter table public.cb_budget_writes enable row level security;alter table public.cb_budget_versions enable row level security;
revoke all on public.cb_shared_budgets,public.cb_budget_categories,public.cb_budget_writes,public.cb_budget_versions from public,anon,authenticated;
create or replace function public.cb_shared_budget(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report jsonb;result jsonb;
begin
 report=public.cb_shared_financial_report(p_project);
 with expenses as (select x.*,coalesce(m.category,'other') as budget_category,coalesce(m.revision,0) as category_revision from jsonb_to_recordset(report->'expenses') as x(id uuid,title text,currency text,commitment numeric,net_paid numeric,outstanding numeric,booking_status text) left join public.cb_budget_categories m on m.expense_id=x.id),
 currencies as (select currency from expenses union select currency from public.cb_shared_budgets where project_id=p_project),
 categories as (select unnest(array['venue','catering','photo','fashion','decor','music','transport','stationery','other']) as category),
 breakdown as (select cur.currency,cat.category,coalesce((b.plan->cat.category->>'target')::numeric,0) as target,coalesce((b.plan->cat.category->>'unbooked')::numeric,0) as unbooked,coalesce(sum(e.commitment),0) as committed,coalesce(sum(e.net_paid),0) as paid,coalesce(sum(e.outstanding),0) as outstanding from currencies cur cross join categories cat left join public.cb_shared_budgets b on b.project_id=p_project and b.currency=cur.currency left join expenses e on e.currency=cur.currency and e.budget_category=cat.category group by cur.currency,cat.category,b.plan),
 totals as (select d.currency,b.target,b.reserve,b.revision,sum(d.committed) as committed,sum(d.paid) as paid,sum(d.outstanding) as outstanding,sum(d.unbooked) as unbooked,sum(d.committed+d.unbooked)+coalesce(b.reserve,0) as forecast,case when b.target is not null then b.target-sum(d.committed+d.unbooked)-b.reserve end as headroom from breakdown d left join public.cb_shared_budgets b on b.project_id=p_project and b.currency=d.currency group by d.currency,b.target,b.reserve,b.revision)
 select jsonb_build_object('project',p_project,'editable',public.cb_project_access(p_project,'write'),'title',report->>'title','generated_at',report->'generated_at',
 'budgets',(select coalesce(jsonb_agg(to_jsonb(b) order by currency),'[]') from public.cb_shared_budgets b where project_id=p_project),
 'totals',(select coalesce(jsonb_agg(to_jsonb(t) order by currency),'[]') from totals t),
 'categories',(select coalesce(jsonb_agg(to_jsonb(d) order by currency,category),'[]') from breakdown d),
 'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by currency,title,id),'[]') from expenses e)) into result;return result;
end;$$;
create or replace function public.cb_save_shared_budget(p_project uuid,p_currency text,p_revision bigint,p_client uuid,p_target numeric,p_reserve numeric,p_plan jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.cb_shared_budgets;prev public.cb_budget_writes;payload jsonb;result jsonb;k text;v jsonb;n numeric;allocated numeric:=0;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'finance') and public.cb_project_access(p_project,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','budget','project',p_project,'currency',p_currency,'revision',p_revision,'target',p_target,'reserve',p_reserve,'plan',p_plan);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_budget_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if coalesce(p_currency,'') !~ '^[A-Z]{3}$' or p_target is null or p_target::text in ('NaN','Infinity','-Infinity') or p_target<=0 or p_target>1000000000000 or p_target<>round(p_target,2) or p_reserve is null or p_reserve::text in ('NaN','Infinity','-Infinity') or p_reserve<0 or p_reserve>p_target or p_reserve<>round(p_reserve,2) then raise exception 'Check the currency, positive target and contingency reserve';end if;
 if jsonb_typeof(p_plan) is distinct from 'object' or octet_length(p_plan::text)>6000 then raise exception 'Enter valid category targets and estimates';end if;
 for k,v in select * from jsonb_each(p_plan) loop
  if k<>all(array['venue','catering','photo','fashion','decor','music','transport','stationery','other']) or jsonb_typeof(v)<>'object' or v-array['target','unbooked']::text[]<>'{}' or jsonb_typeof(v->'target') is distinct from 'number' or jsonb_typeof(v->'unbooked') is distinct from 'number' then raise exception 'Choose valid category targets and unbooked estimates';end if;
  n=(v->>'target')::numeric;if n<0 or n>1000000000000 or n<>round(n,2) then raise exception 'Category targets must be nonnegative amounts';end if;allocated=allocated+n;
  n=(v->>'unbooked')::numeric;if n<0 or n>1000000000000 or n<>round(n,2) then raise exception 'Unbooked estimates must be nonnegative amounts';end if;
 end loop;
 if allocated+p_reserve>p_target then raise exception 'Category targets plus reserve exceed the overall budget';end if;
 select * into b from public.cb_shared_budgets where project_id=p_project and currency=p_currency;
 if coalesce(b.revision,0) is distinct from p_revision then raise exception 'Budget changed. Refresh before editing.' using errcode='PT409';end if;
 insert into public.cb_shared_budgets(project_id,currency,target,reserve,plan,updated_by) values(p_project,p_currency,p_target,p_reserve,p_plan,auth.uid()) on conflict(project_id,currency) do update set target=excluded.target,reserve=excluded.reserve,plan=excluded.plan,revision=public.cb_shared_budgets.revision+1,updated_by=auth.uid(),updated_at=now() returning * into b;
 result=to_jsonb(b);insert into public.cb_budget_versions values(p_project,p_currency,b.revision,auth.uid(),result,now());insert into public.cb_budget_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared budget reviewed',array['finance']);return result;
end;$$;
create or replace function public.cb_set_budget_category(p_expense uuid,p_category text,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;b public.cb_budget_categories;prev public.cb_budget_writes;payload jsonb;result jsonb;
begin
 select project_id into pid from public.cb_shared_expenses where id=p_expense;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','category','expense',p_expense,'category',p_category,'revision',p_revision);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_budget_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if p_category is null or p_category<>all(array['venue','catering','photo','fashion','decor','music','transport','stationery','other']) then raise exception 'Choose a budget category';end if;
 select * into b from public.cb_budget_categories where expense_id=p_expense;
 if coalesce(b.revision,0) is distinct from p_revision then raise exception 'Expense category changed. Refresh before editing.' using errcode='PT409';end if;
 insert into public.cb_budget_categories(expense_id,category,updated_by) values(p_expense,p_category,auth.uid()) on conflict(expense_id) do update set category=excluded.category,revision=public.cb_budget_categories.revision+1,updated_by=auth.uid() returning * into b;
 result=to_jsonb(b);insert into public.cb_budget_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared expense category reviewed',array['finance']);return result;
end;$$;
revoke all on function public.cb_shared_budget(uuid),public.cb_save_shared_budget(uuid,text,bigint,uuid,numeric,numeric,jsonb),public.cb_set_budget_category(uuid,text,bigint,uuid) from public,anon,authenticated;
grant execute on function public.cb_shared_budget(uuid),public.cb_save_shared_budget(uuid,text,bigint,uuid,numeric,numeric,jsonb),public.cb_set_budget_category(uuid,text,bigint,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
