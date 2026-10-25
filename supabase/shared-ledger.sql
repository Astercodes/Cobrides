-- Explicit booking expenses and an append-only payment journal. No funds are moved.
begin;
create table if not exists public.cb_shared_expenses(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 booking_id uuid not null unique references public.cb_vendor_bookings on delete restrict,
 title text not null,currency text not null,agreed_total numeric(18,2) not null,
 schedule jsonb not null default '[]',booking_revision bigint not null,
 reconciled boolean not null default false,reconciliation_note text not null default '',
 revision bigint not null default 1,created_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_shared_payments(
 id uuid primary key default gen_random_uuid(),expense_id uuid not null references public.cb_shared_expenses on delete restrict,
 kind text not null check(kind in ('Payment','Refund')),amount numeric(18,2) not null check(amount>0),paid_on date not null,
 method text not null,reference text not null default '',note text not null default '',
 original_id uuid references public.cb_shared_payments on delete restrict,
 created_by uuid not null references auth.users,created_at timestamptz not null default now()
);
create table if not exists public.cb_shared_ledger_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_shared_ledger_versions(expense_id uuid not null references public.cb_shared_expenses on delete restrict,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(expense_id,revision));
alter table public.cb_shared_expenses enable row level security;
alter table public.cb_shared_payments enable row level security;
alter table public.cb_shared_ledger_writes enable row level security;
alter table public.cb_shared_ledger_versions enable row level security;
revoke all on public.cb_shared_expenses,public.cb_shared_payments,public.cb_shared_ledger_writes,public.cb_shared_ledger_versions from public,anon,authenticated;
create index if not exists cb_shared_expenses_project on public.cb_shared_expenses(project_id,created_at desc);
create index if not exists cb_shared_payments_expense on public.cb_shared_payments(expense_id,created_at);
create or replace function public.cb_shared_ledger(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'finance') then raise exception 'Financial access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'editable',public.cb_project_access(p_project,'write'),
 'expenses',(select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object(
 'booking_status',b.status,'current_booking_revision',b.revision,
 'vendor',v.name,'net_paid',coalesce((select sum(case when p.kind='Payment' then p.amount else -p.amount end) from public.cb_shared_payments p where p.expense_id=e.id),0),
 'payments',(select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at,p.id),'[]') from public.cb_shared_payments p where p.expense_id=e.id),
 'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'at',h.at,'reconciled',h.snapshot->'reconciled','note',h.snapshot->>'reconciliation_note') order by h.revision desc),'[]') from public.cb_shared_ledger_versions h where h.expense_id=e.id)
 ) order by e.created_at desc),'[]') from public.cb_shared_expenses e join public.cb_vendor_bookings b on b.id=e.booking_id join public.cb_shared_vendors v on v.id=b.vendor_id where e.project_id=p_project));
end;$$;
create or replace function public.cb_connect_booking_expense(p_booking uuid,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.cb_vendor_bookings;e public.cb_shared_expenses;pid uuid;payload jsonb;prev public.cb_shared_ledger_writes;result jsonb;
begin
 select v.project_id into pid from public.cb_vendor_bookings x join public.cb_shared_vendors v on v.id=x.vendor_id where x.id=p_booking;
 perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','connect','booking',p_booking,'revision',p_revision);
 if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_shared_ledger_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into b from public.cb_vendor_bookings where id=p_booking;
 select * into e from public.cb_shared_expenses where booking_id=p_booking;
 if not found then
  if b.revision is distinct from p_revision then raise exception 'Booking changed. Refresh before connecting.' using errcode='PT409';end if;
  if b.status='Cancelled' then raise exception 'Cancelled bookings cannot create a new expense';end if;
  insert into public.cb_shared_expenses(project_id,booking_id,title,currency,agreed_total,schedule,booking_revision,created_by)
  values(pid,b.id,b.title,b.quote_snapshot->>'currency',(b.quote_snapshot->>'total')::numeric,b.milestones,b.revision,auth.uid()) returning * into e;
  insert into public.cb_shared_ledger_versions values(e.id,e.revision,auth.uid(),to_jsonb(e),now());
  insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared expense connected',array['finance']);
 end if;
 result=to_jsonb(e);insert into public.cb_shared_ledger_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_record_shared_payment(p_expense uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_shared_expenses;p public.cb_shared_payments;original public.cb_shared_payments;pid uuid;payload jsonb;prev public.cb_shared_ledger_writes;result jsonb;amount numeric;net numeric;refunded numeric;k text;
begin
 select project_id into pid from public.cb_shared_expenses where id=p_expense;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','payment','expense',p_expense,'revision',p_revision,'data',p_data);
 if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_shared_ledger_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into e from public.cb_shared_expenses where id=p_expense;
 if e.revision is distinct from p_revision then raise exception 'Expense changed. Refresh before recording payment.' using errcode='PT409';end if;
 if e.reconciled then raise exception 'Reopen reconciliation before changing payment records';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>7000 or p_data-array['kind','amount','date','method','reference','note','originalId']::text[]<>'{}' then raise exception 'Check payment fields';end if;
 foreach k in array array['kind','date','method','reference','note','originalId'] loop if p_data ? k and jsonb_typeof(p_data->k)<>'string' then raise exception 'Payment text fields must be text';end if;end loop;
 if coalesce(p_data->>'kind','') not in ('Payment','Refund') or jsonb_typeof(p_data->'amount') is distinct from 'number' then raise exception 'Choose a payment type and amount';end if;
 amount=(p_data->>'amount')::numeric;
 if amount<=0 or amount>1000000000000 or amount<>round(amount,2) or coalesce(p_data->>'date','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter a positive amount with at most two decimals and a payment date';end if;
 if (p_data->>'date')::date>current_date then raise exception 'A recorded payment cannot have a future date';end if;
 if coalesce(p_data->>'method','') not in ('Bank transfer','Card','Cash','Other') or length(coalesce(p_data->>'reference',''))>200 or length(coalesce(p_data->>'note',''))>4000 then raise exception 'Check method, reference and notes';end if;
 select coalesce(sum(case when x.kind='Payment' then x.amount else -x.amount end),0) into net from public.cb_shared_payments x where x.expense_id=e.id;
 if p_data->>'kind'='Payment' then
  if nullif(p_data->>'originalId','') is not null then raise exception 'Payments cannot reference another payment';end if;
  if net+amount>e.agreed_total then raise exception 'Payment exceeds the remaining balance';end if;
 else
  select * into original from public.cb_shared_payments where id=nullif(p_data->>'originalId','')::uuid and expense_id=e.id and kind='Payment';
  if not found then raise exception 'Choose the original payment for this refund';end if;
  select coalesce(sum(x.amount),0) into refunded from public.cb_shared_payments x where x.original_id=original.id;
  if amount+refunded>original.amount or (p_data->>'date')::date<original.paid_on then raise exception 'Refund exceeds the original payment or precedes it';end if;
 end if;
 insert into public.cb_shared_payments(expense_id,kind,amount,paid_on,method,reference,note,original_id,created_by) values(e.id,p_data->>'kind',amount,(p_data->>'date')::date,p_data->>'method',coalesce(p_data->>'reference',''),coalesce(p_data->>'note',''),case when p_data->>'kind'='Refund' then original.id else null end,auth.uid()) returning * into p;
 update public.cb_shared_expenses set revision=revision+1,updated_at=now() where id=e.id returning * into e;
 insert into public.cb_shared_ledger_versions values(e.id,e.revision,auth.uid(),to_jsonb(e),now());
 result=jsonb_build_object('expense',e.id,'revision',e.revision,'payment',p.id);insert into public.cb_shared_ledger_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared payment record updated',array['finance']);return result;
end;$$;
create or replace function public.cb_reconcile_shared_expense(p_expense uuid,p_revision bigint,p_client uuid,p_reconciled boolean,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_shared_expenses;pid uuid;prev public.cb_shared_ledger_writes;payload jsonb;result jsonb;net numeric;
begin
 select project_id into pid from public.cb_shared_expenses where id=p_expense;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','reconcile','expense',p_expense,'revision',p_revision,'reconciled',p_reconciled,'note',p_note);
 if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_shared_ledger_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into e from public.cb_shared_expenses where id=p_expense;
 if e.revision is distinct from p_revision then raise exception 'Expense changed. Refresh before reconciling.' using errcode='PT409';end if;
 if p_reconciled is null or length(btrim(coalesce(p_note,''))) not between 1 and 4000 then raise exception 'Add a reconciliation or reopening note';end if;
 select coalesce(sum(case when kind='Payment' then amount else -amount end),0) into net from public.cb_shared_payments where expense_id=e.id;
 if p_reconciled and net<>e.agreed_total then raise exception 'Only a fully settled expense can be reconciled';end if;
 update public.cb_shared_expenses set reconciled=p_reconciled,reconciliation_note=btrim(p_note),revision=revision+1,updated_at=now() where id=e.id returning * into e;
 insert into public.cb_shared_ledger_versions values(e.id,e.revision,auth.uid(),to_jsonb(e),now());result=to_jsonb(e);insert into public.cb_shared_ledger_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared expense reconciliation updated',array['finance']);return result;
end;$$;
revoke all on function public.cb_shared_ledger(uuid),public.cb_connect_booking_expense(uuid,bigint,uuid),public.cb_record_shared_payment(uuid,bigint,uuid,jsonb),public.cb_reconcile_shared_expense(uuid,bigint,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.cb_shared_ledger(uuid),public.cb_connect_booking_expense(uuid,bigint,uuid),public.cb_record_shared_payment(uuid,bigint,uuid,jsonb),public.cb_reconcile_shared_expense(uuid,bigint,uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
commit;
