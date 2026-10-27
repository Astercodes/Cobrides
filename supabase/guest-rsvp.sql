-- Shared guest households and invitation-bound RSVPs. No emails are sent by this migration.
begin;
create table if not exists public.cb_rsvp_households(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 created_by uuid not null references auth.users,local_ref text not null,data jsonb not null,
 token text not null unique default replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),
 revoked boolean not null default false,answers jsonb not null default '[]',revision bigint not null default 1,updated_at timestamptz not null default now(),unique(project_id,created_by,local_ref)
);
create table if not exists public.cb_rsvp_writes(subject text not null,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(subject,client_id));
create table if not exists public.cb_rsvp_history(household_id uuid not null references public.cb_rsvp_households on delete cascade,revision bigint not null,kind text not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(household_id,revision));
alter table public.cb_rsvp_households enable row level security;alter table public.cb_rsvp_writes enable row level security;alter table public.cb_rsvp_history enable row level security;
revoke all on public.cb_rsvp_households,public.cb_rsvp_writes,public.cb_rsvp_history from public,anon,authenticated;
create index if not exists cb_rsvp_households_project on public.cb_rsvp_households(project_id);
create or replace function public.cb_guest_workspace(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'write') then raise exception 'Guest management access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'events',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'local_ref',local_ref,'title',title,'date',details->>'date') order by details->>'date',title),'[]') from public.cb_project_events where project_id=p_project and public.cb_project_event_access(id)),
 'households',(select coalesce(jsonb_agg(to_jsonb(h) order by lower(data->>'title'),id),'[]') from public.cb_rsvp_households h where project_id=p_project));
end;$$;
create or replace function public.cb_save_guest_household(p_project uuid,p_id uuid,p_ref text,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_rsvp_households;prior public.cb_rsvp_writes;payload jsonb;result jsonb;m jsonb;e jsonb;k text;member_ids uuid[]='{}';event_ids uuid[];mid uuid;eid uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;if not public.cb_project_access(p_project,'write') then raise exception 'Guest management access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','household','project',p_project,'id',p_id,'ref',p_ref,'revision',p_revision,'data',p_data);if p_client is null then raise exception 'Request ID required';end if;
 select * into prior from public.cb_rsvp_writes where subject='user:'||auth.uid() and client_id=p_client;if found then if prior.payload is distinct from payload then raise exception 'Details changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>30000 or p_data-array['title','contact','deadline','notes','members']::text[]<>'{}' then raise exception 'Review household details';end if;
 foreach k in array array['title','contact','deadline','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k='notes' then 2000 else 250 end) then raise exception 'Review household text';end if;end loop;
 if length(btrim(p_data->>'title')) not between 1 and 160 then raise exception 'Enter a household name';end if;
 if p_data->>'deadline'<>'' then if p_data->>'deadline' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid reply deadline';end if;perform (p_data->>'deadline')::date;end if;
 if jsonb_typeof(p_data->'members') is distinct from 'array' then raise exception 'Add named guests';end if;
 if jsonb_array_length(p_data->'members') not between 1 and 20 then raise exception 'Add between one and twenty named guests';end if;
 for m in select value from jsonb_array_elements(p_data->'members') loop
 if jsonb_typeof(m)<>'object' or m-array['id','name','events']::text[]<>'{}' or jsonb_typeof(m->'id') is distinct from 'string' or jsonb_typeof(m->'name') is distinct from 'string' or length(btrim(coalesce(m->>'name',''))) not between 1 and 160 then raise exception 'Review guest names';end if;
 mid=(m->>'id')::uuid;if mid=any(member_ids) then raise exception 'A guest appears more than once';end if;member_ids=array_append(member_ids,mid);
 if jsonb_typeof(m->'events') is distinct from 'array' then raise exception 'Choose invited celebrations for each guest';end if;
 if jsonb_array_length(m->'events') not between 1 and 12 then raise exception 'Choose one to twelve invited celebrations per guest';end if;event_ids='{}';
 for e in select value from jsonb_array_elements(m->'events') loop
 if jsonb_typeof(e)<>'string' then raise exception 'Choose a valid celebration';end if;eid=(e#>>'{}')::uuid;
 if eid=any(event_ids) or not exists(select 1 from public.cb_project_events where id=eid and project_id=p_project and public.cb_project_event_access(id)) then raise exception 'Choose accessible celebrations in this wedding';end if;event_ids=array_append(event_ids,eid);
 end loop;end loop;
 if p_id is null then
 if p_revision is distinct from 0::bigint or length(coalesce(p_ref,'')) not between 1 and 250 then raise exception 'Refresh before creating a household' using errcode='PT409';end if;
 if (select count(*) from public.cb_rsvp_households where project_id=p_project)>=2000 then raise exception 'This wedding has reached its household allowance';end if;
 if exists(select 1 from public.cb_rsvp_households where project_id=p_project and created_by=auth.uid() and local_ref=p_ref) then raise exception 'This household is already shared' using errcode='PT409';end if;
 insert into public.cb_rsvp_households(project_id,created_by,local_ref,data) values(p_project,auth.uid(),p_ref,p_data) returning * into h;
 else
 select * into h from public.cb_rsvp_households where id=p_id and project_id=p_project for update;if not found then raise exception 'Household access required' using errcode='42501';end if;
 if h.revision is distinct from p_revision then raise exception 'Guest records changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_rsvp_households set data=p_data,answers=(select coalesce(jsonb_agg(a),'[]') from jsonb_array_elements(h.answers) a where exists(select 1 from jsonb_array_elements(p_data->'members') person_row where person_row->>'id'=a->>'guest' and person_row->'events' ? (a->>'event'))),revision=revision+1,updated_at=now() where id=h.id returning * into h;
 end if;
 result=to_jsonb(h);insert into public.cb_rsvp_history values(h.id,h.revision,'household',result,now());insert into public.cb_rsvp_writes values('user:'||auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Guest household saved',array['guests']);return result;
end;$$;
create or replace function public.cb_guest_invitation(p_household uuid,p_revision bigint,p_client uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_rsvp_households;prior public.cb_rsvp_writes;payload jsonb;pid uuid;result jsonb;
begin
 select project_id into pid from public.cb_rsvp_households where id=p_household;perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_project_access(pid,'write') then raise exception 'Guest management access required' using errcode='42501';end if;
 payload=jsonb_build_object('action',p_action,'household',p_household,'revision',p_revision);if p_client is null then raise exception 'Request ID required';end if;select * into prior from public.cb_rsvp_writes where subject='user:'||auth.uid() and client_id=p_client;
 if found then if prior.payload is distinct from payload then raise exception 'Invitation changed during retry' using errcode='PT409';end if;return prior.response;end if;
 select * into h from public.cb_rsvp_households where id=p_household for update;if h.revision is distinct from p_revision then raise exception 'Guest records changed. Refresh before editing.' using errcode='PT409';end if;
 if p_action='revoke' then update public.cb_rsvp_households set revoked=true where id=h.id;
 elsif p_action='replace' then update public.cb_rsvp_households set revoked=false,token=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','') where id=h.id;
 else raise exception 'Choose revoke or replace';end if;
 update public.cb_rsvp_households set revision=revision+1,updated_at=now() where id=h.id returning * into h;result=to_jsonb(h);insert into public.cb_rsvp_history values(h.id,h.revision,'invitation',result,now());insert into public.cb_rsvp_writes values('user:'||auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_guest_invitation_view(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('title',h.data->>'title','revision',h.revision,'deadline',h.data->>'deadline','open',coalesce(h.data->>'deadline','')='' or (h.data->>'deadline')::date>=(now() at time zone 'UTC')::date,
 'couple',coalesce(s.published->>'names',p.title),'cover',coalesce(s.published->>'cover','assets/wedding.webp'),'customPalette',s.published->'customPalette','answers',h.answers,
 'members',(select coalesce(jsonb_agg(jsonb_build_object('id',m->>'id','name',m->>'name','events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'date',e.details->>'date','time',e.details->>'time','venue',e.details->>'venue','dress',e.details->>'dressCode') order by e.details->>'date',e.title),'[]') from public.cb_project_events e where e.project_id=h.project_id and m->'events' ? e.id::text))),'[]') from jsonb_array_elements(h.data->'members') m))
 from public.cb_rsvp_households h join public.cb_projects p on p.id=h.project_id left join public.cb_wedding_sites s on s.project_id=h.project_id where h.id=p_id and not h.revoked and p.archived_at is null;
$$;
create or replace function public.cb_read_guest_invitation(p_token text) returns jsonb language sql stable security definer set search_path='' as $$
 select public.cb_guest_invitation_view(id) from public.cb_rsvp_households where length(p_token)=64 and p_token ~ '^[a-f0-9]{64}$' and token=p_token;
$$;
create or replace function public.cb_submit_guest_rsvp(p_token text,p_revision bigint,p_client uuid,p_answers jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_rsvp_households;prior public.cb_rsvp_writes;payload jsonb;a jsonb;k text;guest jsonb;seen text[]='{}';pair text;total integer;pid uuid;
begin
 if length(p_token)<>64 or p_token !~ '^[a-f0-9]{64}$' then raise exception 'Invitation unavailable' using errcode='42501';end if;
 select project_id into pid from public.cb_rsvp_households where token=p_token;perform 1 from public.cb_projects where id=pid for update;select * into h from public.cb_rsvp_households where token=p_token for update;
 if not found or h.revoked or not exists(select 1 from public.cb_projects where id=h.project_id and archived_at is null) then raise exception 'Invitation unavailable' using errcode='42501';end if;
 payload=jsonb_build_object('revision',p_revision,'answers',p_answers);if p_client is null then raise exception 'Request ID required';end if;select * into prior from public.cb_rsvp_writes where subject='guest:'||h.id::text||':'||p_token and client_id=p_client;
 if found then if prior.payload is distinct from payload then raise exception 'Response changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if coalesce(h.data->>'deadline','')<>'' and (h.data->>'deadline')::date<(now() at time zone 'UTC')::date then raise exception 'The reply deadline has passed' using errcode='42501';end if;
 if h.revision is distinct from p_revision then raise exception 'Invitation changed. Reload before replying.' using errcode='PT409';end if;
 if (select count(*) from public.cb_rsvp_history where household_id=h.id and kind='response' and at>now()-interval '1 day')>=50 then raise exception 'Too many response updates. Try again later.' using errcode='PT429';end if;
 if jsonb_typeof(p_answers) is distinct from 'array' or octet_length(p_answers::text)>100000 then raise exception 'Review your responses';end if;
 select sum(jsonb_array_length(m->'events')) into total from jsonb_array_elements(h.data->'members') m;
 if jsonb_array_length(p_answers)<>total then raise exception 'Reply for each invited guest and celebration';end if;
 for a in select value from jsonb_array_elements(p_answers) loop
 if jsonb_typeof(a)<>'object' or a-array['guest','event','status','meal','diet','access']::text[]<>'{}' then raise exception 'Review response fields';end if;
 foreach k in array array['guest','event','status','meal','diet','access'] loop if jsonb_typeof(a->k) is distinct from 'string' or length(a->>k)>(case when k in ('diet','access') then 1000 else 160 end) then raise exception 'Review response text';end if;end loop;
 select m into guest from jsonb_array_elements(h.data->'members') m where m->>'id'=a->>'guest';
 if guest is null or not (guest->'events' ? (a->>'event')) or not exists(select 1 from public.cb_project_events where id=(a->>'event')::uuid and project_id=h.project_id) or a->>'status' not in ('Confirmed','Declined') then raise exception 'Respond only for your invited celebrations';end if;
 pair=(a->>'guest')||':'||(a->>'event');if pair=any(seen) then raise exception 'Duplicate guest response';end if;seen=array_append(seen,pair);
 end loop;
 update public.cb_rsvp_households set answers=p_answers,revision=revision+1,updated_at=now() where id=h.id returning * into h;
 insert into public.cb_rsvp_history values(h.id,h.revision,'response',jsonb_build_object('answers',h.answers),now());
 insert into public.cb_rsvp_writes values('guest:'||h.id::text||':'||p_token,p_client,payload,jsonb_build_object('saved',true,'revision',h.revision));return jsonb_build_object('saved',true,'revision',h.revision);
end;$$;
revoke all on function public.cb_guest_workspace(uuid),public.cb_save_guest_household(uuid,uuid,text,bigint,uuid,jsonb),public.cb_guest_invitation(uuid,bigint,uuid,text),public.cb_guest_invitation_view(uuid),public.cb_read_guest_invitation(text),public.cb_submit_guest_rsvp(text,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_guest_workspace(uuid),public.cb_save_guest_household(uuid,uuid,text,bigint,uuid,jsonb),public.cb_guest_invitation(uuid,bigint,uuid,text) to authenticated;
grant execute on function public.cb_read_guest_invitation(text),public.cb_submit_guest_rsvp(text,bigint,uuid,jsonb) to anon,authenticated;
notify pgrst,'reload schema';commit;
