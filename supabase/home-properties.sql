-- Shared home property shortlists, private viewing schedules and explicit follow-up tasks.
-- Run after cobridey-shared-home.sql. No external bookings, applications or payments.
begin;
create table if not exists public.cb_home_properties(id uuid primary key default gen_random_uuid(),home_id uuid not null references public.cb_home_plans on delete cascade,data jsonb not null,revision bigint not null default 1,updated_at timestamptz not null default now());
create unique index if not exists cb_home_one_chosen_property on public.cb_home_properties(home_id) where data->>'status'='Chosen';
create index if not exists cb_home_property_home on public.cb_home_properties(home_id);
create table if not exists public.cb_home_viewings(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.cb_home_properties,data jsonb not null,start_at timestamptz not null,end_at timestamptz not null,revision bigint not null default 1,updated_at timestamptz not null default now(),check(end_at>start_at));
create index if not exists cb_home_viewing_property on public.cb_home_viewings(property_id,start_at);
create table if not exists public.cb_home_viewing_tasks(viewing_id uuid primary key references public.cb_home_viewings,item_id uuid not null unique references public.cb_home_items);
alter table public.cb_home_properties enable row level security;alter table public.cb_home_viewings enable row level security;alter table public.cb_home_viewing_tasks enable row level security;
revoke all on public.cb_home_properties,public.cb_home_viewings,public.cb_home_viewing_tasks from public,anon,authenticated;
create or replace function public.cb_home_property_workspace(p_home uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.cb_home_access(p_home,false) then raise exception 'Home access required' using errcode='42501';end if;
 return jsonb_build_object('home',public.cb_home_summary(p_home),'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'data',p.data,'revision',p.revision) order by p.updated_at desc,p.id),'[]') from public.cb_home_properties p where p.home_id=p_home),'viewings',(select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'property',v.property_id,'data',v.data,'start_at',v.start_at,'end_at',v.end_at,'revision',v.revision,'followup',l.item_id) order by v.start_at,v.id),'[]') from public.cb_home_viewings v join public.cb_home_properties p on p.id=v.property_id left join public.cb_home_viewing_tasks l on l.viewing_id=v.id where p.home_id=p_home));
end;$$;
create or replace function public.cb_save_home_property(p_home uuid,p_home_revision bigint,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_home_plans;r public.cb_home_properties;w public.cb_home_writes;payload jsonb;result jsonb;k text;n numeric;begin
 select * into h from public.cb_home_plans where id=p_home;perform 1 from public.cb_projects where id=h.project_id for update;select * into h from public.cb_home_plans where id=p_home for update;
 if not public.cb_home_access(p_home,true) or h.archived then raise exception 'Home editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','property','home',p_home,'home_revision',p_home_revision,'id',p_id,'revision',p_revision,'data',p_data,'confirm',p_confirm);
 if p_client is null then raise exception 'Request ID required';end if;select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same property details' using errcode='PT409';end if;return w.response;end if;
 if h.revision is distinct from p_home_revision then raise exception 'Home sharing or details changed. Refresh first.' using errcode='PT409';end if;
 if not coalesce(p_confirm,false) then raise exception 'Confirm sharing this property and its quoted costs with your home participants';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','location','url','image','tenure','bedrooms','price','currency','cadence','deposit','fees','status','notes']::text[]<>'{}' then raise exception 'Review property fields';end if;
 foreach k in array array['title','location','url','image','tenure','bedrooms','price','currency','cadence','deposit','fees','status','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k in ('url','image','notes') then 2000 when k='location' then 250 else 160 end) then raise exception 'Review property text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or p_data->>'tenure' not in ('Rent','Buy','Other') or p_data->>'cadence' not in ('Monthly','Yearly','One-time') or p_data->>'status' not in ('Researching','Shortlisted','Chosen','Passed','Archived') or p_data->>'currency'!~'^[A-Z]{3}$' or p_data->>'bedrooms'!~'^([0-9]|[1-9][0-9])$' then raise exception 'Choose title, tenure, currency, bedrooms and status';end if;
 if p_data->>'tenure'='Buy' and p_data->>'cadence'<>'One-time' then raise exception 'Use a one-time asking price for a purchase';end if;
 foreach k in array array['price','deposit','fees'] loop if p_data->>k<>'' then if p_data->>k!~'^([0-9]{1,12})(\.[0-9]{1,2})?$' then raise exception 'Use a nonnegative quoted amount with up to two decimal places';end if;n=(p_data->>k)::numeric;end if;end loop;
 foreach k in array array['url','image'] loop if p_data->>k<>'' and (p_data->>k!~'^https://[^/?#[:space:]]+([/?#]|$)' or p_data->>k~'^https://[^/]*@' or p_data->>k~'[[:space:]]') then raise exception 'Use secure listing and photo links without login details';end if;end loop;
 if p_id is not null then select * into r from public.cb_home_properties where id=p_id and home_id=p_home for update;if r.id is null then raise exception 'Property unavailable' using errcode='42501';end if;end if;
 if coalesce(r.revision,0) is distinct from p_revision then raise exception 'Another device updated this property. Refresh first.' using errcode='PT409';end if;
 if p_data->>'status'='Chosen' and exists(select 1 from public.cb_home_properties where home_id=p_home and data->>'status'='Chosen' and (p_id is null or id<>p_id)) then raise exception 'Review your currently chosen property before choosing another' using errcode='PT409';end if;
 if p_data->>'status' in ('Passed','Archived') and exists(select 1 from public.cb_home_viewings where property_id=r.id and data->>'status' in ('Scheduled','Confirmed')) then raise exception 'Cancel outstanding viewings before passing or archiving this property';end if;
 if r.id is null then if (select count(*) from public.cb_home_properties where home_id=p_home)>=300 then raise exception 'Property shortlist allowance reached';end if;insert into public.cb_home_properties(home_id,data) values(p_home,p_data) returning * into r;
 else update public.cb_home_properties set data=p_data,revision=revision+1,updated_at=now() where id=r.id returning * into r;end if;
 result=jsonb_build_object('id',r.id,'data',r.data,'revision',r.revision);insert into public.cb_home_history values('property',r.id,r.revision,auth.uid(),to_jsonb(r),now());insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_save_home_viewing(p_home uuid,p_home_revision bigint,p_property uuid,p_property_revision bigint,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_home_plans;p public.cb_home_properties;r public.cb_home_viewings;w public.cb_home_writes;payload jsonb;result jsonb;k text;a timestamptz;b timestamptz;sa timestamp;sb timestamp;begin
 select * into h from public.cb_home_plans where id=p_home;perform 1 from public.cb_projects where id=h.project_id for update;select * into h from public.cb_home_plans where id=p_home for update;
 if not public.cb_home_access(p_home,true) or h.archived then raise exception 'Home editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','viewing','home',p_home,'home_revision',p_home_revision,'property',p_property,'property_revision',p_property_revision,'id',p_id,'revision',p_revision,'data',p_data);
 if p_client is null then raise exception 'Request ID required';end if;select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same viewing details' using errcode='PT409';end if;return w.response;end if;
 if h.revision is distinct from p_home_revision then raise exception 'Home sharing or details changed. Refresh first.' using errcode='PT409';end if;
 select * into p from public.cb_home_properties where id=p_property and home_id=p_home for update;if p.id is null then raise exception 'Property unavailable' using errcode='42501';end if;
 if p.revision is distinct from p_property_revision then raise exception 'Property details changed. Refresh first.' using errcode='PT409';end if;
 if p_id is not null then select * into r from public.cb_home_viewings where id=p_id and property_id=p.id for update;if r.id is null then raise exception 'Viewing unavailable' using errcode='42501';end if;end if;
 if coalesce(r.revision,0) is distinct from p_revision then raise exception 'Another device updated this viewing. Refresh first.' using errcode='PT409';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['start','end','zone','status','contact','notes','rating','checks']::text[]<>'{}' then raise exception 'Review viewing fields';end if;
 foreach k in array array['start','end','zone','status','contact','notes','rating'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k='notes' then 2000 when k='contact' then 250 else 100 end) then raise exception 'Review viewing text limits';end if;end loop;
 if p_data->>'status' not in ('Scheduled','Confirmed','Completed','Cancelled') or p_data->>'rating' not in ('','1','2','3','4','5') then raise exception 'Choose viewing status and optional rating';end if;
 if p.data->>'status' in ('Archived','Passed') and p_data->>'status' in ('Scheduled','Confirmed') then raise exception 'Reopen this property before scheduling a viewing';end if;
 if jsonb_typeof(p_data->'checks') is distinct from 'object' or (p_data->'checks')-array['water','power','condition','ventilation','accessibility','noise','commute']::text[]<>'{}' then raise exception 'Review the viewing checklist';end if;
 foreach k in array array['water','power','condition','ventilation','accessibility','noise','commute'] loop if jsonb_typeof(p_data->'checks'->k) is distinct from 'boolean' then raise exception 'Complete the checklist with checked or unchecked items';end if;end loop;
 if p_data->>'start'!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' or p_data->>'end'!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' or not exists(select 1 from pg_timezone_names where name=p_data->>'zone') then raise exception 'Choose valid local viewing times and a time zone';end if;
 sa=(p_data->>'start')::timestamp;sb=(p_data->>'end')::timestamp;a=sa at time zone (p_data->>'zone');b=sb at time zone (p_data->>'zone');
 if to_char(a at time zone (p_data->>'zone'),'YYYY-MM-DD"T"HH24:MI')<>p_data->>'start' or to_char(b at time zone (p_data->>'zone'),'YYYY-MM-DD"T"HH24:MI')<>p_data->>'end' then raise exception 'This local time does not exist because of a clock change';end if;
 if b<=a or b-a>interval '24 hours' then raise exception 'Viewing end must follow its start, within 24 hours';end if;
 if p_data->>'status'='Completed' and a>now() then raise exception 'Complete the viewing after it begins';end if;
 if p_data->>'status' in ('Scheduled','Confirmed') and exists(select 1 from public.cb_home_viewings x join public.cb_home_properties z on z.id=x.property_id where z.home_id=p_home and (p_id is null or x.id<>p_id) and x.data->>'status' in ('Scheduled','Confirmed') and x.start_at<b and x.end_at>a) then raise exception 'This overlaps another home viewing. Review the times first.' using errcode='PT409';end if;
 if r.id is null then if (select count(*) from public.cb_home_viewings v join public.cb_home_properties z on z.id=v.property_id where z.home_id=p_home)>=1000 then raise exception 'Viewing allowance reached';end if;insert into public.cb_home_viewings(property_id,data,start_at,end_at) values(p.id,p_data,a,b) returning * into r;
 else update public.cb_home_viewings set data=p_data,start_at=a,end_at=b,revision=revision+1,updated_at=now() where id=r.id returning * into r;end if;
 result=jsonb_build_object('id',r.id,'property',r.property_id,'data',r.data,'revision',r.revision,'start_at',r.start_at,'end_at',r.end_at);insert into public.cb_home_history values('viewing',r.id,r.revision,auth.uid(),to_jsonb(r),now());insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
-- Explicit bridge to the existing home checklist: one task per viewing, no silently copied notes.
create or replace function public.cb_home_viewing_followup(p_home uuid,p_home_revision bigint,p_viewing uuid,p_viewing_revision bigint,p_client uuid,p_title text,p_due text,p_assignee uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_home_plans;v public.cb_home_viewings;w public.cb_home_writes;payload jsonb;result jsonb;i uuid;begin
 select * into h from public.cb_home_plans where id=p_home;perform 1 from public.cb_projects where id=h.project_id for update;select * into h from public.cb_home_plans where id=p_home for update;
 if not public.cb_home_access(p_home,true) or h.archived then raise exception 'Home editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','viewing-followup','home',p_home,'home_revision',p_home_revision,'viewing',p_viewing,'viewing_revision',p_viewing_revision,'title',p_title,'due',p_due,'assignee',p_assignee);
 if p_client is null then raise exception 'Request ID required';end if;select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same follow-up details' using errcode='PT409';end if;return w.response;end if;
 if h.revision is distinct from p_home_revision then raise exception 'Home sharing or details changed. Refresh first.' using errcode='PT409';end if;
 select x.* into v from public.cb_home_viewings x join public.cb_home_properties p on p.id=x.property_id where x.id=p_viewing and p.home_id=p_home for update of x;
 if v.id is null then raise exception 'Viewing unavailable' using errcode='42501';end if;
 if v.revision is distinct from p_viewing_revision then raise exception 'Viewing changed. Review it again.' using errcode='PT409';end if;
 if v.data->>'status'='Cancelled' then raise exception 'Reopen the viewing before creating a follow-up';end if;
 select item_id into i from public.cb_home_viewing_tasks where viewing_id=v.id;if found then raise exception 'A follow-up is already linked to this viewing' using errcode='PT409';end if;
 result=public.cb_save_home_item(p_home,p_home_revision,null,0,gen_random_uuid(),jsonb_build_object('title',coalesce(p_title,''),'room','Whole home','kind','Responsibility','status','Planned','due',coalesce(p_due,''),'notes','','requiresSetup',false),p_assignee,null,false);i=(result->>'id')::uuid;
 insert into public.cb_home_viewing_tasks values(v.id,i);insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_home_property_workspace(uuid),public.cb_save_home_property(uuid,bigint,uuid,bigint,uuid,jsonb,boolean),public.cb_save_home_viewing(uuid,bigint,uuid,bigint,uuid,bigint,uuid,jsonb),public.cb_home_viewing_followup(uuid,bigint,uuid,bigint,uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.cb_home_property_workspace(uuid),public.cb_save_home_property(uuid,bigint,uuid,bigint,uuid,jsonb,boolean),public.cb_save_home_viewing(uuid,bigint,uuid,bigint,uuid,bigint,uuid,jsonb),public.cb_home_viewing_followup(uuid,bigint,uuid,bigint,uuid,text,text,uuid) to authenticated;
notify pgrst,'reload schema';commit;
