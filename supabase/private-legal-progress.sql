-- Owner-only administrative checklist progress. Does not verify legal eligibility or issue documents.
begin;
create table if not exists public.cb_legal_progress(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,record_ref text not null,definition text not null,spec jsonb not null,data jsonb not null,revision bigint not null default 1,updated_at timestamptz not null default now(),primary key(user_id,scope,project_ref,record_ref,definition));
create table if not exists public.cb_legal_progress_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_legal_progress_history(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,record_ref text not null,definition text not null,revision bigint not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(user_id,scope,project_ref,record_ref,definition,revision));
alter table public.cb_legal_progress enable row level security;alter table public.cb_legal_progress_writes enable row level security;alter table public.cb_legal_progress_history enable row level security;
revoke all on public.cb_legal_progress,public.cb_legal_progress_writes,public.cb_legal_progress_history from public,anon,authenticated;
create or replace function public.cb_legal_confirmation_ok(r jsonb,p_today date) returns boolean language plpgsql immutable set search_path='' as $$
declare verified date;required boolean;begin
 required=coalesce(r->>'guideKey','')<>'' and r->>'guideOrder'='1';
 if not required and coalesce(r->>'verified','')='' then return true;end if;
 if coalesce(r->>'source','')!~'^https://[^/?#[:space:]]+([/?#]|$)' or r->>'source'~'^https://[^/]*@' or r->>'source'~'[[:space:]]' or coalesce(r->>'verified','')!~'^\d{4}-\d{2}-\d{2}$' then return false;end if;
 begin verified=(r->>'verified')::date;exception when datetime_field_overflow or invalid_datetime_format then return false;end;return verified<=p_today;end;$$;
create or replace function public.cb_prepare_legal_progress(p_scope text,p_project text,p_zone text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;spec jsonb;sig text;checks jsonb;d jsonb;row public.cb_legal_progress;results jsonb='[]';today date;complete boolean;skipped boolean;fresh boolean;begin
 if auth.uid() is null or p_scope is null or p_scope not in ('personal','demo') then raise exception 'Sign in to open private preparation' using errcode='42501';end if;
 if length(coalesce(p_project,'')) not between 1 and 200 or not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Choose your project and a valid time zone';end if;today=(now() at time zone p_zone)::date;
 perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 for r in select x.value from (select distinct on (body->'value'->>'id') body->'value' value from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and (body->'path'=jsonb_build_array(p_scope,'legalRecords') or p_scope='personal' and body->'path'=jsonb_build_array('legalRecords')) order by body->'value'->>'id',jsonb_array_length(body->'path') desc) x where x.value->>'projectId'=p_project and x.value->>'kind' in ('Marriage registration','Identity & supporting documents','Appointments & witnesses','Name & account updates','International documentation') loop
 if jsonb_typeof(r->'checklist') is distinct from 'array' then results=results||jsonb_build_array(jsonb_build_object('record',r->>'id','error','Edit this record to add its checklist actions.'));continue;end if;
 if jsonb_array_length(r->'checklist')>40 or exists(select 1 from jsonb_array_elements(r->'checklist') v where jsonb_typeof(v->'id') is distinct from 'string' or length(coalesce(v->>'id','')) not between 1 and 200 or jsonb_typeof(v->'title') is distinct from 'string') or (select count(*)<>count(distinct value->>'id') from jsonb_array_elements(r->'checklist')) then results=results||jsonb_build_array(jsonb_build_object('record',r->>'id','error','Edit this record to give each action its own checklist entry.'));continue;end if;
 spec=jsonb_build_object('kind',r->>'kind','guide',r->>'guideKey','order',r->'guideOrder','items',(select coalesce(jsonb_agg(jsonb_build_object('id',value->>'id','title',value->>'title') order by ord),'[]') from jsonb_array_elements(r->'checklist') with ordinality a(value,ord)));sig=md5(spec::text);
 select * into row from public.cb_legal_progress where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=r->>'id' and definition=sig;
 if not found then
 fresh=not exists(select 1 from public.cb_legal_progress where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=r->>'id');
 checks=case when fresh then (select coalesce(jsonb_agg(value->>'id'),'[]') from jsonb_array_elements(r->'checklist') where value->'done'='true'::jsonb) else '[]'::jsonb end;
 skipped=fresh and coalesce(r->'guideSkipped'='true'::jsonb,false) and r->>'kind' in ('Name & account updates','International documentation');
 complete=fresh and r->>'status'='Complete' and jsonb_array_length(checks)=jsonb_array_length(r->'checklist') and public.cb_legal_confirmation_ok(r,today) and not skipped;
 d=jsonb_build_object('definition_changed',not fresh,'checks',checks,'completed',coalesce(complete,false),'skipped',coalesce(skipped,false),'confirmation',case when complete then jsonb_build_object('source',coalesce(r->>'source',''),'verified',coalesce(r->>'verified','')) else null end);
 insert into public.cb_legal_progress values(auth.uid(),p_scope,p_project,r->>'id',sig,spec,d,1,now()) returning * into row;
 insert into public.cb_legal_progress_history values(auth.uid(),p_scope,p_project,r->>'id',sig,1,jsonb_build_object('data',d,'origin',case when fresh then 'Previous progress' else 'Changed checklist' end),now());end if;
 d=row.data;complete=coalesce((d->>'completed')::boolean,false);fresh=complete and (not public.cb_legal_confirmation_ok(r,today) or d->'confirmation' is distinct from jsonb_build_object('source',coalesce(r->>'source',''),'verified',coalesce(r->>'verified','')));
 results=results||jsonb_build_array(jsonb_build_object('record',r->>'id','definition',sig,'revision',row.revision,'checks',d->'checks','completed',complete and not fresh,'skipped',d->'skipped','needs_review',fresh,'definition_changed',coalesce((d->>'definition_changed')::boolean,false),'editable',not coalesce((r->>'archived')::boolean,false)));
 end loop;return jsonb_build_object('scope',p_scope,'project',p_project,'records',results);end;$$;
create or replace function public.cb_save_legal_progress(p_scope text,p_project text,p_record text,p_definition text,p_revision bigint,p_client uuid,p_action text,p_item text,p_value boolean,p_source text,p_verified text,p_zone text) returns jsonb language plpgsql security definer set search_path='' as $$
declare prepared jsonb;v jsonb;r jsonb;row public.cb_legal_progress;old public.cb_legal_progress_writes;payload jsonb;result jsonb;d jsonb;checks jsonb;begin
 prepared=public.cb_prepare_legal_progress(p_scope,p_project,p_zone);select value into v from jsonb_array_elements(prepared->'records') where value->>'record'=p_record;
 if v is null or v->>'error' is not null or not coalesce((v->>'editable')::boolean,false) then raise exception 'Save an active private checklist first' using errcode='42501';end if;
 if v->>'definition' is distinct from p_definition then raise exception 'The checklist changed. Refresh before updating progress.' using errcode='PT409';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'record',p_record,'definition',p_definition,'revision',p_revision,'action',p_action,'item',p_item,'value',p_value,'source',p_source,'verified',p_verified,'zone',p_zone);if p_client is null then raise exception 'Request ID required';end if;
 select * into old from public.cb_legal_progress_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the same checklist update' using errcode='PT409';end if;return old.response;end if;
 select * into row from public.cb_legal_progress where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=p_record and definition=p_definition for update;
 if row.revision is distinct from p_revision then raise exception 'Another device updated this checklist. Refresh first.' using errcode='PT409';end if;
 if p_action is null or p_action not in ('Check','Complete','Skip') or p_value is null then raise exception 'Choose a checklist action';end if;
 d=row.data;if coalesce((v->>'needs_review')::boolean,false) then d=jsonb_set(d,'{completed}','false');end if;checks=d->'checks';
 if p_action='Check' then
 if p_item is null or not exists(select 1 from jsonb_array_elements(row.spec->'items') where value->>'id'=p_item) then raise exception 'Choose an action from this checklist';end if;
 select coalesce(jsonb_agg(value),'[]') into checks from jsonb_array_elements(checks) where value #>> '{}'<>p_item;
 if p_value then checks=checks||jsonb_build_array(p_item);else d=jsonb_set(d,'{completed}','false');end if;d=jsonb_set(d,'{checks}',checks);
 elsif p_action='Skip' then
 if row.spec->>'kind' not in ('Name & account updates','International documentation') then raise exception 'This category cannot be marked not applicable';end if;
 d=jsonb_set(jsonb_set(d,'{skipped}',to_jsonb(p_value)),'{completed}','false');
 else
 if p_value then
 if jsonb_array_length(checks)<>jsonb_array_length(row.spec->'items') then raise exception 'Finish every checklist action before completing this step';end if;
 select body->'value' into r from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_record and (body->'path'=jsonb_build_array(p_scope,'legalRecords') or p_scope='personal' and body->'path'=jsonb_build_array('legalRecords')) order by jsonb_array_length(body->'path') desc limit 1;
 if coalesce(r->>'source','') is distinct from coalesce(p_source,'') or coalesce(r->>'verified','') is distinct from coalesce(p_verified,'') then raise exception 'The authority-source record changed. Refresh the record before completing this step.' using errcode='PT409';end if;
 if not public.cb_legal_confirmation_ok(r,(now() at time zone p_zone)::date) then raise exception 'Record the official source and a valid date you checked it before completing this step';end if;
 d=jsonb_set(d,'{confirmation}',jsonb_build_object('source',coalesce(r->>'source',''),'verified',coalesce(r->>'verified','')));end if;
 d=jsonb_set(jsonb_set(d,'{completed}',to_jsonb(p_value)),'{skipped}','false');end if;
 d=jsonb_set(d,'{definition_changed}','false');
 update public.cb_legal_progress set data=d,revision=revision+1,updated_at=now() where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=p_record and definition=p_definition returning * into row;
 result=jsonb_build_object('record',p_record,'definition',p_definition,'revision',row.revision,'checks',d->'checks','completed',d->'completed','skipped',d->'skipped');insert into public.cb_legal_progress_writes values(auth.uid(),p_client,payload,result);insert into public.cb_legal_progress_history values(auth.uid(),p_scope,p_project,p_record,p_definition,row.revision,jsonb_build_object('data',d),now());return result;
end;$$;
revoke all on function public.cb_legal_confirmation_ok(jsonb,date),public.cb_prepare_legal_progress(text,text,text),public.cb_save_legal_progress(text,text,text,text,bigint,uuid,text,text,boolean,text,text,text) from public,anon,authenticated;
grant execute on function public.cb_prepare_legal_progress(text,text,text),public.cb_save_legal_progress(text,text,text,text,bigint,uuid,text,text,boolean,text,text,text) to authenticated;
notify pgrst,'reload schema';commit;
