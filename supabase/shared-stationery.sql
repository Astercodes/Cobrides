-- Shared stationery drafts, owner approvals and revision-specific proofs.
begin;
create table if not exists public.cb_stationery_drafts(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 created_by uuid not null references auth.users,local_ref text not null,event_id uuid references public.cb_project_events on delete restrict,
 data jsonb not null,archived boolean not null default false,revision bigint not null default 1,
 approved_revision bigint,approved_event_revision bigint,approved_by uuid references auth.users,approved_at timestamptz,
 updated_at timestamptz not null default now(),unique(project_id,created_by,local_ref)
);
create table if not exists public.cb_stationery_history(draft_id uuid not null references public.cb_stationery_drafts on delete cascade,revision bigint not null,actor_id uuid not null references auth.users,kind text not null,note text not null default '',snapshot jsonb not null,at timestamptz not null default now(),primary key(draft_id,revision));
create table if not exists public.cb_stationery_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
alter table public.cb_stationery_drafts enable row level security;alter table public.cb_stationery_history enable row level security;alter table public.cb_stationery_writes enable row level security;
revoke all on public.cb_stationery_drafts,public.cb_stationery_history,public.cb_stationery_writes from public,anon,authenticated;
create index if not exists cb_stationery_project on public.cb_stationery_drafts(project_id);
create or replace function public.cb_stationery_access(p_draft uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_stationery_drafts d where d.id=p_draft and public.cb_project_access(d.project_id,'write') and (d.event_id is null or public.cb_project_event_access(d.event_id)));
$$;
create or replace function public.cb_stationery_workspace(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'write') then raise exception 'Stationery management access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'owner',public.cb_project_access(p_project,'owner'),
 'events',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'local_ref',local_ref,'title',title,'revision',revision,'date',details->>'date','time',details->>'time','venue',details->>'venue') order by details->>'date',title),'[]') from public.cb_project_events where project_id=p_project and public.cb_project_event_access(id)),
 'drafts',(select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('approved_current',coalesce(not d.archived and d.approved_revision=d.revision and d.approved_by=p.owner_id and (d.event_id is null or d.approved_event_revision=e.revision),false),'event_title',e.title,'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'kind',h.kind,'note',h.note,'at',h.at) order by h.revision desc),'[]') from public.cb_stationery_history h where draft_id=d.id)) order by d.archived,d.updated_at desc,d.id),'[]') from public.cb_stationery_drafts d join public.cb_projects p on p.id=d.project_id left join public.cb_project_events e on e.id=d.event_id where d.project_id=p_project and public.cb_stationery_access(d.id)));
end;$$;
create or replace function public.cb_save_stationery_draft(p_project uuid,p_id uuid,p_ref text,p_revision bigint,p_client uuid,p_event uuid,p_data jsonb,p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.cb_stationery_drafts;prior public.cb_stationery_writes;payload jsonb;result jsonb;k text;c jsonb;limit_length integer;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Stationery management access required' using errcode='42501';end if;
 if p_event is not null and not exists(select 1 from public.cb_project_events where id=p_event and project_id=p_project and public.cb_project_event_access(id)) then raise exception 'Choose an accessible celebration in this wedding';end if;
 payload=jsonb_build_object('action','draft','project',p_project,'id',p_id,'ref',p_ref,'revision',p_revision,'event',p_event,'data',p_data,'archived',p_archived);if p_client is null then raise exception 'Request ID required';end if;
 select * into prior from public.cb_stationery_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prior.payload is distinct from payload then raise exception 'Draft changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>8000 or p_data-array['title','kind','design','names','recipient','message','details','reply','palette']::text[]<>'{}' or p_archived is null then raise exception 'Review stationery details';end if;
 foreach k in array array['title','kind','design','names','recipient','message','details','reply'] loop
 limit_length=case k when 'message' then 600 when 'details' then 1200 when 'reply' then 240 when 'title' then 120 else 160 end;
 if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>limit_length then raise exception 'Review stationery text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or length(btrim(p_data->>'names'))<1 or p_data->>'kind' not in ('Save the date','Formal invitation','Ceremony program','RSVP card','Thank-you card','Bridal shower','Menu','Place card') or p_data->>'design' not in ('Botanical romance','Burgundy rose','Terracotta bloom','Sage herbarium','Ivory letterpress','Modern arch','Art Deco','Midnight gala','Blush silk','Coastal elegance') then raise exception 'Choose a title, couple names and stationery design';end if;
 if jsonb_typeof(p_data->'palette') is distinct from 'array' then raise exception 'Choose your stationery colours';end if;
 if jsonb_array_length(p_data->'palette') not between 2 and 8 then raise exception 'Choose two to eight colours';end if;
 for c in select value from jsonb_array_elements(p_data->'palette') loop if jsonb_typeof(c)<>'string' or c#>>'{}' !~* '^#[a-f0-9]{6}$' then raise exception 'Use valid HEX colours';end if;end loop;
 if p_id is null then
 if p_revision is distinct from 0::bigint or length(coalesce(p_ref,'')) not between 1 and 250 then raise exception 'Refresh before creating a draft' using errcode='PT409';end if;
 if exists(select 1 from public.cb_stationery_drafts where project_id=p_project and created_by=auth.uid() and local_ref=p_ref) then raise exception 'This design is already shared. Open its current draft.' using errcode='PT409';end if;
 if (select count(*) from public.cb_stationery_drafts where project_id=p_project)>=1000 then raise exception 'This wedding has reached its shared stationery allowance';end if;
 insert into public.cb_stationery_drafts(project_id,created_by,local_ref,event_id,data,archived) values(p_project,auth.uid(),p_ref,p_event,p_data,p_archived) returning * into d;
 else
 select * into d from public.cb_stationery_drafts where id=p_id and project_id=p_project;
 if not found or not public.cb_stationery_access(d.id) then raise exception 'Draft access required' using errcode='42501';end if;
 if d.revision is distinct from p_revision then raise exception 'Draft changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_stationery_drafts set event_id=p_event,data=p_data,archived=p_archived,revision=revision+1,approved_revision=null,approved_event_revision=null,approved_by=null,approved_at=null,updated_at=now() where id=d.id returning * into d;
 end if;
 result=to_jsonb(d);insert into public.cb_stationery_history values(d.id,d.revision,auth.uid(),'Draft saved','',result,now());insert into public.cb_stationery_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared stationery draft saved',array['stationery']);return result;
end;$$;
create or replace function public.cb_review_stationery(p_draft uuid,p_revision bigint,p_event_revision bigint,p_client uuid,p_action text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.cb_stationery_drafts;pid uuid;prior public.cb_stationery_writes;payload jsonb;result jsonb;event_revision bigint;
begin
 select project_id into pid from public.cb_stationery_drafts where id=p_draft;perform 1 from public.cb_projects where id=pid for update;
 select * into d from public.cb_stationery_drafts where id=p_draft;
 if not coalesce(public.cb_stationery_access(d.id) and public.cb_project_access(pid,'owner') and not d.archived,false) then raise exception 'The wedding owner must review this design' using errcode='42501';end if;
 payload=jsonb_build_object('action',p_action,'draft',p_draft,'revision',p_revision,'event_revision',p_event_revision,'note',p_note);if p_client is null then raise exception 'Request ID required';end if;
 select * into prior from public.cb_stationery_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prior.payload is distinct from payload then raise exception 'Review changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if d.revision is distinct from p_revision then raise exception 'Draft changed. Refresh before reviewing.' using errcode='PT409';end if;
 if p_note is null or length(p_note)>1000 or p_action is null or p_action not in ('approve','withdraw') then raise exception 'Check the review action and note';end if;
 if p_action='approve' then
 if d.data->>'kind'='Place card' and length(btrim(d.data->>'recipient'))<1 then raise exception 'Add the recipient name before approving a place card';end if;
 if d.event_id is not null then select revision into event_revision from public.cb_project_events where id=d.event_id;if event_revision is distinct from p_event_revision then raise exception 'Celebration details changed. Refresh and review the date and venue.' using errcode='PT409';end if;end if;
 update public.cb_stationery_drafts set revision=revision+1,approved_revision=revision+1,approved_event_revision=event_revision,approved_by=auth.uid(),approved_at=now(),updated_at=now() where id=d.id returning * into d;
 else
 if length(btrim(p_note))<1 then raise exception 'Add a reason for withdrawing approval';end if;
 update public.cb_stationery_drafts set revision=revision+1,approved_revision=null,approved_event_revision=null,approved_by=null,approved_at=null,updated_at=now() where id=d.id returning * into d;
 end if;
 result=to_jsonb(d);insert into public.cb_stationery_history values(d.id,d.revision,auth.uid(),case when p_action='approve' then 'Proof approved' else 'Approval withdrawn' end,btrim(p_note),result,now());insert into public.cb_stationery_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_stationery_proof(p_draft uuid,p_revision bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d public.cb_stationery_drafts;approved boolean;
begin
 select * into d from public.cb_stationery_drafts where id=p_draft;
 if not coalesce(public.cb_stationery_access(d.id) and not d.archived,false) then raise exception 'Proof access required' using errcode='42501';end if;
 if d.revision is distinct from p_revision then raise exception 'Design changed. Refresh before exporting.' using errcode='PT409';end if;
 select d.approved_revision=d.revision and d.approved_by=p.owner_id and (d.event_id is null or d.approved_event_revision=e.revision) into approved from public.cb_projects p left join public.cb_project_events e on e.id=d.event_id where p.id=d.project_id;
 return jsonb_build_object('id',d.id,'revision',d.revision,'data',d.data,'approved',coalesce(approved,false));
end;$$;
revoke all on function public.cb_stationery_access(uuid),public.cb_stationery_workspace(uuid),public.cb_save_stationery_draft(uuid,uuid,text,bigint,uuid,uuid,jsonb,boolean),public.cb_review_stationery(uuid,bigint,bigint,uuid,text,text),public.cb_stationery_proof(uuid,bigint) from public,anon,authenticated;
grant execute on function public.cb_stationery_workspace(uuid),public.cb_save_stationery_draft(uuid,uuid,text,bigint,uuid,uuid,jsonb,boolean),public.cb_review_stationery(uuid,bigint,bigint,uuid,text,text),public.cb_stationery_proof(uuid,bigint) to authenticated;
notify pgrst,'reload schema';commit;
