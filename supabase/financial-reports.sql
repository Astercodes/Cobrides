-- Read-only financial report snapshot, restricted to accepted financial collaborators.
begin;
create or replace function public.cb_shared_financial_report(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not coalesce(public.cb_project_access(p_project,'read') and public.cb_project_access(p_project,'finance'),false) then raise exception 'Financial access required' using errcode='42501';end if;
 with expenses as (
 select e.id,e.title,e.currency,e.agreed_total as original_total,coalesce(e.settlement_total,e.agreed_total) as commitment,e.reconciled,e.revision,
 v.id as vendor_id,v.name as vendor,coalesce(v.details->>'category','Other') as category,b.status as booking_status,
 coalesce(pay.gross_paid,0) as gross_paid,coalesce(pay.refunded,0) as refunded,
 coalesce(pay.gross_paid,0)-coalesce(pay.refunded,0) as net_paid,
 coalesce(e.settlement_total,e.agreed_total)-coalesce(pay.gross_paid,0)+coalesce(pay.refunded,0) as outstanding
 from public.cb_shared_expenses e join public.cb_vendor_bookings b on b.id=e.booking_id join public.cb_shared_vendors v on v.id=b.vendor_id
 left join lateral (select sum(p.amount) filter(where p.kind='Payment') as gross_paid,sum(p.amount) filter(where p.kind='Refund') as refunded from public.cb_shared_payments p where p.expense_id=e.id) pay on true where e.project_id=p_project
 ),totals as (
 select currency,count(*) as expenses,sum(original_total) as original_total,sum(commitment) as commitment,sum(gross_paid) as gross_paid,sum(refunded) as refunded,sum(net_paid) as net_paid,sum(outstanding) as outstanding,count(*) filter(where reconciled) as reconciled from expenses group by currency
 ),vendors as (
 select vendor_id,vendor,currency,count(*) as expenses,sum(commitment) as commitment,sum(net_paid) as net_paid,sum(outstanding) as outstanding from expenses group by vendor_id,vendor,currency
 ),journal as (
 select p.id,p.expense_id,e.title as expense,e.vendor,e.currency,p.kind,p.amount,p.paid_on,p.method,p.reference,p.note,p.original_id,p.created_at from public.cb_shared_payments p join expenses e on e.id=p.expense_id
 ) select jsonb_build_object('project',p_project,'title',(select title from public.cb_projects where id=p_project),'generated_at',statement_timestamp(),
 'totals',(select coalesce(jsonb_agg(to_jsonb(t) order by currency),'[]') from totals t),
 'vendors',(select coalesce(jsonb_agg(to_jsonb(v) order by vendor,currency,vendor_id),'[]') from vendors v),
 'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by vendor,title,id),'[]') from expenses e),
 'payments',(select coalesce(jsonb_agg(to_jsonb(j) order by paid_on,created_at,id),'[]') from journal j)) into result;
 return result;
end;$$;
revoke all on function public.cb_shared_financial_report(uuid) from public,anon,authenticated;
grant execute on function public.cb_shared_financial_report(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
