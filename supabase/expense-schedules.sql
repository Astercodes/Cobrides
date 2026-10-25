-- Reviewed replacement payment schedules; paid transactions and original agreements are preserved.
begin;
alter table public.cb_shared_expenses add column if not exists schedule_total numeric(18,2) check(schedule_total>=0);
create table if not exists public.cb_expense_schedule_changes(
 id uuid primary key default gen_random_uuid(),expense_id uuid not null references public.cb_shared_expenses on delete restrict,
 previous_schedule jsonb not null,new_schedule jsonb not null,commitment_total numeric(18,2) not null,reason text not null,
 revision bigint not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),unique(expense_id,revision)
);
alter table public.cb_expense_schedule_changes enable row level security;
revoke all on public.cb_expense_schedule_changes from public,anon,authenticated;
create or replace function public.cb_replace_expense_schedule(p_expense uuid,p_revision bigint,p_client uuid,p_schedule jsonb,p_reason text,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_shared_expenses;pid uuid;prev public.cb_shared_ledger_writes;payload jsonb;result jsonb;m jsonb;total numeric:=0;ids text[]:=array[]::text[];amount numeric;
begin
 select project_id into pid from public.cb_shared_expenses where id=p_expense;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','schedule','expense',p_expense,'revision',p_revision,'schedule',p_schedule,'reason',p_reason,'confirm',p_confirm);
 if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_shared_ledger_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into e from public.cb_shared_expenses where id=p_expense;
 if e.revision is distinct from p_revision then raise exception 'Expense changed. Refresh before reviewing the schedule.' using errcode='PT409';end if;
 if e.reconciled then raise exception 'Reopen reconciliation before reviewing the schedule';end if;
 if exists(select 1 from public.cb_vendor_bookings where id=e.booking_id and status='Cancelled') then raise exception 'Cancelled bookings do not generate payment reminders';end if;
 if p_confirm is distinct from true then raise exception 'Confirm the revised payment dates with the vendor';end if;
 if length(btrim(coalesce(p_reason,''))) not between 1 and 4000 then raise exception 'Add a reason for the schedule review';end if;
 if jsonb_typeof(p_schedule) is distinct from 'array' or octet_length(p_schedule::text)>20000 then raise exception 'Enter a valid payment schedule';end if;
 if jsonb_array_length(p_schedule)>12 then raise exception 'Use up to twelve payment deadlines';end if;
 for m in select value from jsonb_array_elements(p_schedule) loop
  if jsonb_typeof(m) is distinct from 'object' or m-array['id','title','amount','due']::text[]<>'{}' or jsonb_typeof(m->'id') is distinct from 'string' or coalesce(m->>'id','') !~ '^[A-Za-z0-9_-]{1,80}$' or m->>'id'=any(ids) then raise exception 'Each deadline needs a unique valid ID';end if;
  if jsonb_typeof(m->'title') is distinct from 'string' or length(btrim(coalesce(m->>'title',''))) not between 1 and 120 or jsonb_typeof(m->'amount') is distinct from 'number' or jsonb_typeof(m->'due') is distinct from 'string' or coalesce(m->>'due','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Each deadline needs a name, amount and date';end if;
  perform (m->>'due')::date;amount=(m->>'amount')::numeric;
  if amount<=0 or amount>1000000000000 or amount<>round(amount,2) then raise exception 'Deadline amounts must be positive with at most two decimals';end if;
  total=total+amount;ids=array_append(ids,m->>'id');
 end loop;
 if jsonb_array_length(p_schedule)>0 and total<>coalesce(e.settlement_total,e.agreed_total) then raise exception 'Payment deadlines must total the current commitment, including payments already made';end if;
 insert into public.cb_expense_schedule_changes(expense_id,previous_schedule,new_schedule,commitment_total,reason,revision,created_by) values(e.id,e.schedule,p_schedule,coalesce(e.settlement_total,e.agreed_total),btrim(p_reason),e.revision+1,auth.uid());
 update public.cb_shared_expenses set schedule=p_schedule,schedule_total=coalesce(settlement_total,agreed_total),revision=revision+1,updated_at=now() where id=e.id returning * into e;
 insert into public.cb_shared_ledger_versions values(e.id,e.revision,auth.uid(),to_jsonb(e),now());result=to_jsonb(e);insert into public.cb_shared_ledger_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared payment schedule reviewed',array['finance']);return result;
end;$$;
revoke all on function public.cb_replace_expense_schedule(uuid,bigint,uuid,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function public.cb_replace_expense_schedule(uuid,bigint,uuid,jsonb,text,boolean) to authenticated;

create or replace function public.cb_shared_ledger(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'finance') then raise exception 'Financial access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'editable',public.cb_project_access(p_project,'write'),
 'expenses',(select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object(
 'schedule_history',(select coalesce(jsonb_agg(to_jsonb(h) order by h.revision desc),'[]') from public.cb_expense_schedule_changes h where h.expense_id=e.id),'settlements',(select coalesce(jsonb_agg(to_jsonb(s) order by s.revision desc),'[]') from public.cb_expense_settlements s where s.expense_id=e.id),'booking_status',b.status,'current_booking_revision',b.revision,
 'vendor',v.name,'net_paid',coalesce((select sum(case when p.kind='Payment' then p.amount else -p.amount end) from public.cb_shared_payments p where p.expense_id=e.id),0),
 'payments',(select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at,p.id),'[]') from public.cb_shared_payments p where p.expense_id=e.id),
 'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'at',h.at,'reconciled',h.snapshot->'reconciled','note',h.snapshot->>'reconciliation_note') order by h.revision desc),'[]') from public.cb_shared_ledger_versions h where h.expense_id=e.id)
 ) order by e.created_at desc),'[]') from public.cb_shared_expenses e join public.cb_vendor_bookings b on b.id=e.booking_id join public.cb_shared_vendors v on v.id=b.vendor_id where e.project_id=p_project));
end;$$;
create or replace function public.cb_expense_deadlines(p_expense uuid) returns table(milestone text,title text,due date,remaining numeric) language sql stable security definer set search_path='' as $$
 with expense as (
 select e.*,coalesce((select sum(case when p.kind='Payment' then p.amount else -p.amount end) from public.cb_shared_payments p where p.expense_id=e.id),0) as paid
 from public.cb_shared_expenses e join public.cb_vendor_bookings b on b.id=e.booking_id join public.cb_projects project on project.id=e.project_id
 where e.id=p_expense and not e.reconciled and b.status<>'Cancelled' and project.archived_at is null and coalesce(e.settlement_total,e.agreed_total)=coalesce(e.schedule_total,e.agreed_total)
 ),plan as (
 select s->>'id' as mid,s->>'title' as label,(s->>'due')::date as deadline,(s->>'amount')::numeric as amount,e.paid,
 sum((s->>'amount')::numeric) over(order by (s->>'due')::date,s->>'id') as running
 from expense e cross join lateral jsonb_array_elements(e.schedule) s
 ) select mid,label,deadline,least(amount,greatest(0,running-paid)) from plan where running>paid;
$$;
notify pgrst,'reload schema';
commit;
