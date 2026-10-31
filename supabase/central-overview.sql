-- Read-only overview of canonical shared wedding records. No writes or publication.
begin;
create or replace function public.cb_central_overview(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p public.cb_projects;evs jsonb;task_rows jsonb;guest_rows jsonb='[]';budget jsonb=null;payment_rows jsonb='[]';decisions jsonb;issue_count bigint;can_finance boolean;can_guests boolean;
begin
 select * into p from public.cb_projects where id=p_project;
 if p.id is null or not coalesce(public.cb_project_access(p.id,'read'),false) then raise exception 'Wedding access required' using errcode='42501';end if;
 can_finance=coalesce(public.cb_project_access(p.id,'finance'),false);can_guests=coalesce(public.cb_project_access(p.id,'write'),false);
 select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'title',t.title,'done',t.done,'due_date',t.due_date,'plan',jsonb_build_object('category',t.plan->>'category','status',t.plan->>'status'),'kind',t.kind,'local_ref',t.local_ref) order by t.id),'[]') into task_rows from public.cb_tasks t where t.project_id=p.id and public.cb_task_visible(t.id);
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'local_ref',e.local_ref,'title',e.title,'date',e.details->>'date','time',e.details->>'time','venue',e.details->>'venue','status',e.details->>'status') order by e.details->>'date',e.title,e.id),'[]') into evs from public.cb_project_events e where e.project_id=p.id and public.cb_experience_member(e.id,auth.uid());
 if can_guests then
  select coalesce(jsonb_agg(jsonb_build_object('event',e.id,'title',e.title,'date',e.details->>'date','Confirmed',g.yes,'Declined',g.no,'Awaiting',g.total-g.yes-g.no,'total',g.total) order by e.details->>'date',e.title,e.id),'[]') into guest_rows
  from public.cb_project_events e cross join lateral (
   select count(*) as total,count(*) filter(where a.status='Confirmed') as yes,count(*) filter(where a.status='Declined') as no
   from public.cb_rsvp_households h cross join lateral jsonb_array_elements(h.data->'members') m
   left join lateral (select answer->>'status' as status from jsonb_array_elements(h.answers) answer where answer->>'guest'=m->>'id' and answer->>'event'=e.id::text limit 1) a on true
   where h.project_id=p.id and m->'events' ? e.id::text
  ) g where e.project_id=p.id and public.cb_experience_member(e.id,auth.uid());
 end if;
 if can_finance then
  budget=public.cb_shared_budget(p.id);
  select coalesce(jsonb_agg(jsonb_build_object('expense',x.id,'title',x.title,'currency',x.currency,'due',d.due,'remaining',d.remaining) order by d.due,x.id),'[]') into payment_rows from public.cb_shared_expenses x cross join lateral public.cb_expense_deadlines(x.id) d where x.project_id=p.id and d.remaining>0;
 end if;
 select jsonb_build_object('pending',count(*) filter(where public.cb_decision_summary(d.id)->>'status'<>'Approved')) into decisions from public.cb_decisions d where d.project_id=p.id and public.cb_decision_access(d.id);
 select count(*) into issue_count from public.cb_experience_issues i join public.cb_project_events e on e.id=i.event_id where e.project_id=p.id and public.cb_experience_member(e.id,auth.uid()) and i.data->>'status'<>'Resolved';
 return jsonb_build_object('project',p.id,'title',p.title,'date',p.details->>'date','dateStatus',p.details->>'dateStatus','generated_at',statement_timestamp(),'tasks',task_rows,'events',evs,'guests',guest_rows,'can_guests',can_guests,'can_finance',can_finance,'budget',case when budget is null then null else jsonb_build_object('project',p.id,'totals',budget->'totals') end,'payments',payment_rows,'decisions',decisions,'open_issues',issue_count);
end;$$;
revoke all on function public.cb_central_overview(uuid) from public,anon,authenticated;
grant execute on function public.cb_central_overview(uuid) to authenticated;
notify pgrst,'reload schema';commit;
