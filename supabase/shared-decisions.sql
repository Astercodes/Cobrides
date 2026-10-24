begin;
create table if not exists public.cb_decisions(
 id uuid primary key default gen_random_uuid(),seq bigint generated always as identity unique,
 project_id uuid not null references public.cb_projects on delete cascade,client_id uuid not null,
 created_by uuid not null references auth.users,title text not null check(length(btrim(title)) between 1 and 200),
 notes text not null default '' check(length(notes)<=5000),options jsonb not null,
 approvers uuid[] not null, currency text not null default 'USD' check(currency ~ '^[A-Z]{3}$'),due_date date,
 revision bigint not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(project_id,client_id)
);
create table if not exists public.cb_decision_responses(
 decision_id uuid references public.cb_decisions on delete cascade,user_id uuid references auth.users,
 revision bigint not null,option_id text not null,approved boolean not null default false,at timestamptz not null default now(),
 primary key(decision_id,user_id,revision)
);
create table if not exists public.cb_decision_response_log(id bigint generated always as identity primary key,decision_id uuid references public.cb_decisions on delete cascade,user_id uuid not null references auth.users,revision bigint not null,option_id text not null,approved boolean not null,at timestamptz not null default now());
alter table public.cb_decision_response_log enable row level security;
revoke all on public.cb_decision_response_log from public,anon,authenticated;
create table if not exists public.cb_decision_comments(
 id bigint generated always as identity primary key,decision_id uuid references public.cb_decisions on delete cascade,
 author_id uuid not null references auth.users,client_id uuid not null,body text not null check(length(btrim(body)) between 1 and 3000),
 created_at timestamptz not null default now(),unique(decision_id,author_id,client_id)
);
create table if not exists public.cb_decision_versions(decision_id uuid references public.cb_decisions on delete cascade,revision bigint not null,snapshot jsonb not null,actor_id uuid not null references auth.users,at timestamptz not null default now(),primary key(decision_id,revision));
alter table public.cb_decision_versions enable row level security;
revoke all on public.cb_decision_versions from public,anon,authenticated;
alter table public.cb_decisions enable row level security;
alter table public.cb_decision_responses enable row level security;
alter table public.cb_decision_comments enable row level security;
revoke all on public.cb_decisions,public.cb_decision_responses,public.cb_decision_comments from public,anon,authenticated;
create or replace function public.cb_decision_access(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_decisions d where d.id=p_id and public.cb_project_access(d.project_id,'read') and
 (d.created_by=auth.uid() or public.cb_project_access(d.project_id,'write') or auth.uid()=any(d.approvers)));
$$;
create or replace function public.cb_decision_summary(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(d)||jsonb_build_object('seq',d.seq::text,'approvals',(select count(*) from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.approved and r.user_id=any(d.approvers)),
 'winning_option',(select min(r.option_id) from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.approved and r.user_id=any(d.approvers) having count(*)=cardinality(d.approvers) and count(distinct r.option_id)=1),'status',case when cardinality(d.approvers)>0 and (select count(*)=cardinality(d.approvers) and count(distinct r.option_id)=1 from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.approved and r.user_id=any(d.approvers)) then 'Approved' else 'Awaiting response' end)
 from public.cb_decisions d where d.id=p_id;
$$;
create or replace function public.cb_save_decision(p_project uuid,p_id uuid,p_client uuid,p_revision bigint,p_title text,p_notes text,p_options jsonb,p_approvers uuid[],p_currency text,p_due date) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result public.cb_decisions; option jsonb; allowed uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Decision editing access denied' using errcode='42501';end if;
 if p_options is null or jsonb_typeof(p_options)<>'array' or jsonb_array_length(p_options) not between 2 and 8 or octet_length(p_options::text)>24000 then raise exception 'Add between two and eight options';end if;
 for option in select jsonb_array_elements(p_options) loop
 if option-array['id','title','detail','amount']::text[]<>'{}'::jsonb or jsonb_typeof(option)<>'object' or coalesce(option->>'id','') !~ '^[a-zA-Z0-9_-]{1,80}$' or length(btrim(coalesce(option->>'title',''))) not between 1 and 160 or length(coalesce(option->>'detail',''))>1500 then raise exception 'Add a name and valid ID for each option';end if;
 if option ? 'amount' and (jsonb_typeof(option->'amount')<>'number' or (option->>'amount')::numeric<0 or (option->>'amount')::numeric>1000000000000) then raise exception 'Use non-negative option prices';end if;
 end loop;
 if (select count(distinct x->>'id') from jsonb_array_elements(p_options) x)<>jsonb_array_length(p_options) then raise exception 'Options need unique IDs';end if;
 if p_approvers is null or cardinality(p_approvers) not between 1 and 20 or array_position(p_approvers,null) is not null or cardinality(p_approvers)<>(select count(distinct x) from unnest(p_approvers) x) then raise exception 'Choose between one and twenty approvers';end if;
 foreach allowed in array p_approvers loop if not public.cb_collab_user_access(allowed,p_project,'read') then raise exception 'Choose active accepted wedding teammates';end if;end loop;
 if p_id is null then
  select * into result from public.cb_decisions where project_id=p_project and client_id=p_client;
  if found then
   if result.created_by<>auth.uid() or result.title<>btrim(p_title) or result.notes is distinct from p_notes or result.options is distinct from p_options or result.approvers is distinct from p_approvers or result.currency is distinct from p_currency or result.due_date is distinct from p_due then raise exception 'Decision changed during retry' using errcode='PT409';end if;
   return public.cb_decision_summary(result.id);
  end if;
  insert into public.cb_decisions(project_id,client_id,created_by,title,notes,options,approvers,currency,due_date) values(p_project,p_client,auth.uid(),btrim(p_title),p_notes,p_options,p_approvers,p_currency,p_due) returning * into result;
 else
  update public.cb_decisions set title=btrim(p_title),notes=p_notes,options=p_options,approvers=p_approvers,currency=p_currency,due_date=p_due,revision=revision+1,updated_at=now() where id=p_id and project_id=p_project and revision=p_revision returning * into result;
  if not found then raise exception 'Proposal changed. Reload before saving.' using errcode='PT409';end if;
 end if;
 insert into public.cb_decision_versions(decision_id,revision,snapshot,actor_id) values(result.id,result.revision,to_jsonb(result),auth.uid());
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Shared decision proposal saved');
 return public.cb_decision_summary(result.id);
end; $$;
create or replace function public.cb_list_decisions(p_project uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Decision access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(row order by seq desc),'[]') from (select d.seq,public.cb_decision_summary(d.id) row from public.cb_decisions d where d.project_id=p_project and public.cb_decision_access(d.id) and (p_before is null or d.seq<p_before) order by d.seq desc limit 30) batch);
end; $$;
create or replace function public.cb_decision_detail(p_id uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.cb_decision_access(p_id) then raise exception 'Decision access denied' using errcode='42501';end if;
 select public.cb_decision_summary(p_id)||jsonb_build_object('responses',(select coalesce(jsonb_agg(jsonb_build_object('user_id',r.user_id,'option_id',r.option_id,'approved',r.approved,'at',r.at)),'[]') from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision),
 'people',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(p.full_name,'Wedding teammate'))),'[]') from auth.users u left join public.cb_profiles p on p.user_id=u.id where u.id=any(d.approvers)),
 'comments',(select coalesce(jsonb_agg(row order by id),'[]') from (select c.id,jsonb_build_object('id',c.id::text,'body',c.body,'author_id',c.author_id,'name',coalesce(p.full_name,'Wedding teammate'),'at',c.created_at) row from public.cb_decision_comments c left join public.cb_profiles p on p.user_id=c.author_id where c.decision_id=d.id and (p_before is null or c.id<p_before) order by c.id desc limit 50) batch),
 'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',v.revision,'title',v.snapshot->>'title','options',v.snapshot->'options','at',v.at,'responses',(select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(p.full_name,'Wedding teammate'),'option_id',r.option_id,'approved',r.approved,'at',r.at)),'[]') from public.cb_decision_response_log r left join public.cb_profiles p on p.user_id=r.user_id where r.decision_id=v.decision_id and r.revision=v.revision),'approvals',(select count(*) from public.cb_decision_responses r where r.decision_id=v.decision_id and r.revision=v.revision and r.approved)) order by v.revision desc),'[]') from (select * from public.cb_decision_versions where decision_id=d.id order by revision desc limit 20) v),
 'editable',public.cb_project_access(d.project_id,'write'),'archived',exists(select 1 from public.cb_projects p where p.id=d.project_id and p.archived_at is not null)) into result from public.cb_decisions d where d.id=p_id;
 return result;
end; $$;
create or replace function public.cb_respond_decision(p_id uuid,p_revision bigint,p_option text,p_approve boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.cb_decisions;
begin
 select * into d from public.cb_decisions where id=p_id for update;
 if not found or not public.cb_decision_access(p_id) or not auth.uid()=any(d.approvers) or exists(select 1 from public.cb_projects where id=d.project_id and archived_at is not null) then raise exception 'Approval access denied' using errcode='42501';end if;
 if d.revision is distinct from p_revision then raise exception 'Proposal changed. Review its latest options before responding.' using errcode='PT409';end if;
 if not exists(select 1 from jsonb_array_elements(d.options) x where x->>'id'=p_option) or p_approve is null then raise exception 'Choose an existing option';end if;
 if exists(select 1 from public.cb_decision_responses where decision_id=p_id and user_id=auth.uid() and revision=d.revision and option_id=p_option and approved=p_approve) then return public.cb_decision_summary(p_id);end if;
 insert into public.cb_decision_responses(decision_id,user_id,revision,option_id,approved) values(p_id,auth.uid(),d.revision,p_option,p_approve) on conflict(decision_id,user_id,revision) do update set option_id=excluded.option_id,approved=excluded.approved,at=now();
 insert into public.cb_decision_response_log(decision_id,user_id,revision,option_id,approved) values(p_id,auth.uid(),d.revision,p_option,p_approve);
 insert into public.cb_project_activity(project_id,actor_id,action) values(d.project_id,auth.uid(),case when p_approve then 'Decision approval recorded' else 'Decision preference recorded' end);
 return public.cb_decision_summary(p_id);
end; $$;
create or replace function public.cb_comment_decision(p_id uuid,p_client uuid,p_body text) returns void language plpgsql security definer set search_path='' as $$
declare d public.cb_decisions;previous text;
begin
 select * into d from public.cb_decisions where id=p_id for update;
 if not found or not public.cb_decision_access(p_id) or exists(select 1 from public.cb_projects where id=d.project_id and archived_at is not null) then raise exception 'Decision discussion access denied' using errcode='42501';end if;
 select body into previous from public.cb_decision_comments where decision_id=p_id and author_id=auth.uid() and client_id=p_client;
 if found then if previous<>p_body then raise exception 'Comment changed during retry' using errcode='PT409';end if;return;end if;
 insert into public.cb_decision_comments(decision_id,author_id,client_id,body) values(p_id,auth.uid(),p_client,p_body);
end; $$;
revoke all on function public.cb_decision_access(uuid),public.cb_decision_summary(uuid),public.cb_save_decision(uuid,uuid,uuid,bigint,text,text,jsonb,uuid[],text,date),public.cb_list_decisions(uuid,bigint),public.cb_decision_detail(uuid,bigint),public.cb_respond_decision(uuid,bigint,text,boolean),public.cb_comment_decision(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.cb_save_decision(uuid,uuid,uuid,bigint,text,text,jsonb,uuid[],text,date),public.cb_list_decisions(uuid,bigint),public.cb_decision_detail(uuid,bigint),public.cb_respond_decision(uuid,bigint,text,boolean),public.cb_comment_decision(uuid,uuid,text) to authenticated;
create or replace function public.cb_decision_people(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'write') then raise exception 'Decision editing access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(p.full_name,'Wedding teammate'))),'[]') from (select owner_id id from public.cb_projects where id=p_project union select user_id from public.cb_members where project_id=p_project) u left join public.cb_profiles p on p.user_id=u.id where public.cb_collab_user_access(u.id,p_project,'read'));
end; $$;
revoke all on function public.cb_decision_people(uuid) from public,anon,authenticated;
grant execute on function public.cb_decision_people(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
