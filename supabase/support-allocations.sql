-- Assign already received support to recorded expenses. No vendor payment is inferred.
begin;
create table if not exists public.cb_support_allocations(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 contribution_id uuid not null references public.cb_shared_contributions on delete restrict,expense_id uuid not null references public.cb_shared_expenses on delete restrict,
 amount numeric(18,2) not null check(amount>0),note text not null,status text not null default 'Active' check(status in ('Active','Released')),
 revision bigint not null default 1,created_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_support_allocation_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_support_allocation_versions(allocation_id uuid not null references public.cb_support_allocations on delete restrict,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(allocation_id,revision));
alter table public.cb_support_allocations enable row level security;
alter table public.cb_support_allocation_writes enable row level security;
alter table public.cb_support_allocation_versions enable row level security;
revoke all on public.cb_support_allocations,public.cb_support_allocation_writes,public.cb_support_allocation_versions from public,anon,authenticated;
create index if not exists cb_support_allocations_source on public.cb_support_allocations(contribution_id) where status='Active';
create index if not exists cb_support_allocations_target on public.cb_support_allocations(expense_id) where status='Active';
create or replace function public.cb_support_allocations(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'read') and public.cb_project_access(p_project,'finance'),false) then raise exception 'Financial access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'editable',public.cb_project_access(p_project,'write'),
 'contributions',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'title',c.title,'sponsor',c.sponsor,'kind',c.kind,'currency',c.currency,
 'received',coalesce((select sum(r.amount) from public.cb_contribution_receipts r where r.contribution_id=c.id and r.voided_at is null),0),
 'assigned',coalesce((select sum(a.amount) from public.cb_support_allocations a where a.contribution_id=c.id and a.status='Active'),0)) order by c.title,c.id),'[]') from public.cb_shared_contributions c where c.project_id=p_project),
 'expenses',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'currency',e.currency,'commitment',coalesce(e.settlement_total,e.agreed_total),'booking_status',b.status,'assigned',coalesce((select sum(a.amount) from public.cb_support_allocations a where a.expense_id=e.id and a.status='Active'),0)) order by e.title,e.id),'[]') from public.cb_shared_expenses e join public.cb_vendor_bookings b on b.id=e.booking_id where e.project_id=p_project),
 'allocations',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'note',h.snapshot->>'note','amount',h.snapshot->'amount','status',h.snapshot->>'status','at',h.at) order by h.revision desc),'[]') from public.cb_support_allocation_versions h where h.allocation_id=a.id)) order by a.created_at desc),'[]') from public.cb_support_allocations a where a.project_id=p_project));
end;$$;
create or replace function public.cb_save_support_allocation(p_project uuid,p_id uuid,p_revision bigint,p_client uuid,p_contribution uuid,p_expense uuid,p_amount numeric,p_note text,p_release boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.cb_support_allocations;c public.cb_shared_contributions;e public.cb_shared_expenses;prev public.cb_support_allocation_writes;payload jsonb;result jsonb;received numeric;assigned numeric;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'finance') and public.cb_project_access(p_project,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('project',p_project,'id',p_id,'revision',p_revision,'source',p_contribution,'expense',p_expense,'amount',p_amount,'note',p_note,'release',p_release);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_support_allocation_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<=0 or p_amount>1000000000000 or p_amount<>round(p_amount,2) or p_release is null or length(btrim(coalesce(p_note,''))) not between 1 and 4000 then raise exception 'Enter a positive amount, review note and valid action';end if;
 select * into c from public.cb_shared_contributions where id=p_contribution and project_id=p_project;select * into e from public.cb_shared_expenses where id=p_expense and project_id=p_project;
 if c.id is null or e.id is null then raise exception 'Choose a contribution and expense from this wedding';end if;
 if c.currency<>e.currency then raise exception 'Contribution and expense currencies must match';end if;
 if p_id is not null then
  select * into a from public.cb_support_allocations where id=p_id and project_id=p_project;
  if not found then raise exception 'Support assignment unavailable' using errcode='42501';end if;
  if a.revision is distinct from p_revision then raise exception 'Support assignment changed. Refresh before editing.' using errcode='PT409';end if;
  if a.status='Released' then raise exception 'Released assignments are preserved. Create a new assignment.';end if;
  if a.contribution_id<>c.id or a.expense_id<>e.id then raise exception 'Release this assignment before choosing a different source or expense';end if;
 elsif p_release then raise exception 'Choose an existing assignment to release';end if;
 if not p_release then
  if exists(select 1 from public.cb_vendor_bookings where id=e.booking_id and status='Cancelled') then raise exception 'Cancelled bookings cannot receive new support assignments';end if;
  select coalesce(sum(r.amount),0) into received from public.cb_contribution_receipts r where r.contribution_id=c.id and r.voided_at is null;
  select coalesce(sum(x.amount),0) into assigned from public.cb_support_allocations x where x.contribution_id=c.id and x.status='Active' and x.id is distinct from p_id;
  if assigned+p_amount>received then raise exception 'Assignment exceeds received support. Record receipt or release other assignments first.';end if;
  select coalesce(sum(x.amount),0) into assigned from public.cb_support_allocations x where x.expense_id=e.id and x.status='Active' and x.id is distinct from p_id;
  if assigned+p_amount>coalesce(e.settlement_total,e.agreed_total) then raise exception 'Assigned support exceeds this expense commitment';end if;
 end if;
 if p_id is null then insert into public.cb_support_allocations(project_id,contribution_id,expense_id,amount,note,created_by) values(p_project,c.id,e.id,p_amount,btrim(p_note),auth.uid()) returning * into a;
 else update public.cb_support_allocations set amount=case when p_release then amount else p_amount end,note=btrim(p_note),status=case when p_release then 'Released' else 'Active' end,revision=revision+1,updated_at=now() where id=a.id returning * into a;end if;
 result=to_jsonb(a);insert into public.cb_support_allocation_versions values(a.id,a.revision,auth.uid(),result,now());insert into public.cb_support_allocation_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared support assignment reviewed',array['finance']);return result;
end;$$;
create or replace function public.cb_support_integrity_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid;assigned numeric;received numeric;
begin
 if TG_TABLE_NAME='cb_shared_expenses' then
  perform 1 from public.cb_projects where id=new.project_id for update;
  select coalesce(sum(amount),0) into assigned from public.cb_support_allocations where expense_id=new.id and status='Active';
  if assigned>coalesce(new.settlement_total,new.agreed_total) or assigned>0 and new.currency<>old.currency then raise exception 'Release or reduce assigned support before changing this expense commitment';end if;return new;
 else
  if old.voided_at is not null or new.voided_at is null then return new;end if;
  select project_id into pid from public.cb_shared_contributions where id=old.contribution_id;perform 1 from public.cb_projects where id=pid for update;
  select coalesce(sum(amount),0) into assigned from public.cb_support_allocations where contribution_id=old.contribution_id and status='Active';
  select coalesce(sum(amount),0) into received from public.cb_contribution_receipts where contribution_id=old.contribution_id and voided_at is null;
  if assigned>received-old.amount then raise exception 'Release assigned support before correcting this receipt';end if;return new;
 end if;
end;$$;
drop trigger if exists cb_support_expense_integrity on public.cb_shared_expenses;
create trigger cb_support_expense_integrity before update on public.cb_shared_expenses for each row execute function public.cb_support_integrity_guard();
drop trigger if exists cb_support_receipt_integrity on public.cb_contribution_receipts;
create trigger cb_support_receipt_integrity before update on public.cb_contribution_receipts for each row execute function public.cb_support_integrity_guard();
revoke all on function public.cb_support_allocations(uuid),public.cb_save_support_allocation(uuid,uuid,bigint,uuid,uuid,uuid,numeric,text,boolean),public.cb_support_integrity_guard() from public,anon,authenticated;
grant execute on function public.cb_support_allocations(uuid),public.cb_save_support_allocation(uuid,uuid,bigint,uuid,uuid,uuid,numeric,text,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
