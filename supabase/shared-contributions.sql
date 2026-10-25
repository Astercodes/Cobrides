-- Private shared pledges and recorded receipts. This does not transfer funds.
begin;
create table if not exists public.cb_shared_contributions(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 title text not null,sponsor text not null,contributor uuid references auth.users,currency text not null,amount numeric(18,2) not null,
 kind text not null,due date,notes text not null default '',status text not null default 'Active',revision bigint not null default 1,
 created_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_contribution_receipts(
 id uuid primary key default gen_random_uuid(),contribution_id uuid not null references public.cb_shared_contributions on delete cascade,
 amount numeric(18,2) not null,received_on date not null,note text not null default '',created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 voided_at timestamptz,voided_by uuid references auth.users,void_reason text
);
create table if not exists public.cb_contribution_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_contribution_versions(contribution_id uuid not null references public.cb_shared_contributions on delete cascade,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(contribution_id,revision));
alter table public.cb_shared_contributions enable row level security;
alter table public.cb_contribution_receipts enable row level security;
alter table public.cb_contribution_writes enable row level security;
alter table public.cb_contribution_versions enable row level security;
revoke all on public.cb_shared_contributions,public.cb_contribution_receipts,public.cb_contribution_writes,public.cb_contribution_versions from public,anon,authenticated;
create index if not exists cb_shared_contributions_project on public.cb_shared_contributions(project_id,created_at desc);
create index if not exists cb_contribution_receipts_parent on public.cb_contribution_receipts(contribution_id);
create or replace function public.cb_shared_contributions(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare financial boolean;
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding access required' using errcode='42501';end if;
 financial=public.cb_project_access(p_project,'finance');
 return jsonb_build_object('project',p_project,'financial',financial,'editable',financial and public.cb_project_access(p_project,'write'),
 'members',case when financial and public.cb_project_access(p_project,'write') then (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(p.full_name,''),u.email))),'[]') from auth.users u left join public.cb_profiles p on p.user_id=u.id where public.cb_collab_user_access(u.id,p_project,'read')) else '[]'::jsonb end,
 'records',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('received',coalesce((select sum(amount) from public.cb_contribution_receipts where contribution_id=c.id and voided_at is null),0),
 'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at,r.id),'[]') from public.cb_contribution_receipts r where r.contribution_id=c.id),
 'history',case when financial then (select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'at',at) order by revision desc),'[]') from public.cb_contribution_versions where contribution_id=c.id) else '[]'::jsonb end) order by c.created_at desc),'[]') from public.cb_shared_contributions c where c.project_id=p_project and (financial or c.contributor=auth.uid())));
end;$$;
create or replace function public.cb_save_contribution(p_project uuid,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.cb_shared_contributions;prev public.cb_contribution_writes;payload jsonb;result jsonb;amount numeric;recipient uuid;k text;got numeric;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'finance') and public.cb_project_access(p_project,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','pledge','project',p_project,'id',p_id,'revision',p_revision,'data',p_data);
 if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_contribution_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>10000 or p_data-array['title','sponsor','contributor','currency','amount','kind','due','notes','status']::text[]<>'{}' then raise exception 'Check contribution fields';end if;
 foreach k in array array['title','sponsor','contributor','currency','kind','due','notes','status'] loop if p_data ? k and jsonb_typeof(p_data->k)<>'string' then raise exception 'Contribution text fields must be text';end if;end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 200 or length(btrim(coalesce(p_data->>'sponsor',''))) not between 1 and 200 or length(coalesce(p_data->>'notes',''))>4000 or coalesce(p_data->>'currency','') !~ '^[A-Z]{3}$' or coalesce(p_data->>'kind','') not in ('Cash','In-kind','Item sponsorship') or coalesce(p_data->>'status','Active') not in ('Active','Cancelled') then raise exception 'Check the pledge name, sponsor, currency and type';end if;
 if jsonb_typeof(p_data->'amount') is distinct from 'number' then raise exception 'Enter a contribution amount';end if;amount=(p_data->>'amount')::numeric;
 if amount<=0 or amount>1000000000000 or amount<>round(amount,2) then raise exception 'Enter a positive amount with at most two decimals';end if;
 if coalesce(p_data->>'due','')<>'' and p_data->>'due' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid deadline';end if;
 recipient=nullif(p_data->>'contributor','')::uuid;if recipient is not null and not public.cb_collab_user_access(recipient,p_project,'read') then raise exception 'Choose an accepted contributor from this wedding';end if;
 if p_id is null then
  insert into public.cb_shared_contributions(project_id,title,sponsor,contributor,currency,amount,kind,due,notes,status,created_by) values(p_project,btrim(p_data->>'title'),btrim(p_data->>'sponsor'),recipient,p_data->>'currency',amount,p_data->>'kind',nullif(p_data->>'due','')::date,coalesce(p_data->>'notes',''),coalesce(p_data->>'status','Active'),auth.uid()) returning * into c;
 else
  select * into c from public.cb_shared_contributions where id=p_id and project_id=p_project;
  if not found then raise exception 'Contribution unavailable' using errcode='42501';end if;
  if c.revision is distinct from p_revision then raise exception 'Contribution changed. Refresh before editing.' using errcode='PT409';end if;
  select coalesce(sum(r.amount),0) into got from public.cb_contribution_receipts r where r.contribution_id=c.id and r.voided_at is null;
  if amount<got then raise exception 'Pledge cannot be below recorded receipts';end if;
  if exists(select 1 from public.cb_contribution_receipts where contribution_id=c.id) and (c.currency<>p_data->>'currency' or c.kind<>p_data->>'kind' or c.contributor is distinct from recipient) then raise exception 'Keep the currency, type and contributor of recorded receipts';end if;
  update public.cb_shared_contributions set title=btrim(p_data->>'title'),sponsor=btrim(p_data->>'sponsor'),contributor=recipient,currency=p_data->>'currency',amount=(p_data->>'amount')::numeric,kind=p_data->>'kind',due=nullif(p_data->>'due','')::date,notes=coalesce(p_data->>'notes',''),status=coalesce(p_data->>'status','Active'),revision=revision+1,updated_at=now() where id=c.id returning * into c;
 end if;
 result=to_jsonb(c);insert into public.cb_contribution_versions values(c.id,c.revision,auth.uid(),result,now());insert into public.cb_contribution_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared contribution updated',array['finance']);return result;
end;$$;
create or replace function public.cb_record_contribution_receipt(p_contribution uuid,p_revision bigint,p_client uuid,p_amount numeric,p_date date,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.cb_shared_contributions;pid uuid;prev public.cb_contribution_writes;payload jsonb;result jsonb;r public.cb_contribution_receipts;got numeric;
begin
 select project_id into pid from public.cb_shared_contributions where id=p_contribution;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','receipt','id',p_contribution,'revision',p_revision,'amount',p_amount,'date',p_date,'note',p_note);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_contribution_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into c from public.cb_shared_contributions where id=p_contribution;
 if c.revision is distinct from p_revision then raise exception 'Contribution changed. Refresh before recording receipt.' using errcode='PT409';end if;
 if c.status='Cancelled' then raise exception 'Cancelled pledges cannot receive new receipts';end if;
 if p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<=0 or p_amount>1000000000000 or p_amount<>round(p_amount,2) or p_date is null or p_date>current_date or length(coalesce(p_note,''))>4000 then raise exception 'Enter a positive receipt amount, past or current date and valid note';end if;
 select coalesce(sum(amount),0) into got from public.cb_contribution_receipts where contribution_id=c.id and voided_at is null;
 if got+p_amount>c.amount then raise exception 'Receipt exceeds the remaining pledge. Review the pledge first.';end if;
 insert into public.cb_contribution_receipts(contribution_id,amount,received_on,note,created_by) values(c.id,p_amount,p_date,coalesce(p_note,''),auth.uid()) returning * into r;
 update public.cb_shared_contributions set revision=revision+1,updated_at=now() where id=c.id returning * into c;
 insert into public.cb_contribution_versions values(c.id,c.revision,auth.uid(),to_jsonb(c),now());result=jsonb_build_object('receipt',r.id,'revision',c.revision);insert into public.cb_contribution_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared contribution receipt recorded',array['finance']);return result;
end;$$;
create or replace function public.cb_void_contribution_receipt(p_receipt uuid,p_revision bigint,p_client uuid,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.cb_contribution_receipts;c public.cb_shared_contributions;pid uuid;prev public.cb_contribution_writes;payload jsonb;result jsonb;
begin
 select c2.project_id into pid from public.cb_contribution_receipts r2 join public.cb_shared_contributions c2 on c2.id=r2.contribution_id where r2.id=p_receipt;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_project_access(pid,'finance') and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','void','receipt',p_receipt,'revision',p_revision,'reason',p_reason);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_contribution_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into r from public.cb_contribution_receipts where id=p_receipt;select * into c from public.cb_shared_contributions where id=r.contribution_id;
 if c.revision is distinct from p_revision then raise exception 'Contribution changed. Refresh before correcting a receipt.' using errcode='PT409';end if;
 if r.voided_at is not null then raise exception 'This receipt is already voided';end if;
 if length(btrim(coalesce(p_reason,''))) not between 1 and 4000 then raise exception 'Add a reason for correcting this receipt';end if;
 update public.cb_contribution_receipts set voided_at=now(),voided_by=auth.uid(),void_reason=btrim(p_reason) where id=r.id;
 update public.cb_shared_contributions set revision=revision+1,updated_at=now() where id=c.id returning * into c;
 insert into public.cb_contribution_versions values(c.id,c.revision,auth.uid(),to_jsonb(c),now());result=jsonb_build_object('revision',c.revision);insert into public.cb_contribution_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared contribution receipt corrected',array['finance']);return result;
end;$$;
revoke all on function public.cb_shared_contributions(uuid),public.cb_save_contribution(uuid,uuid,bigint,uuid,jsonb),public.cb_record_contribution_receipt(uuid,bigint,uuid,numeric,date,text),public.cb_void_contribution_receipt(uuid,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.cb_shared_contributions(uuid),public.cb_save_contribution(uuid,uuid,bigint,uuid,jsonb),public.cb_record_contribution_receipt(uuid,bigint,uuid,numeric,date,text),public.cb_void_contribution_receipt(uuid,bigint,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
