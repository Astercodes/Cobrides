-- Private invoice and payment-proof links, protected by financial permissions.
begin;
create table if not exists public.cb_expense_files(
 id uuid primary key default gen_random_uuid(),expense_id uuid not null references public.cb_shared_expenses on delete restrict,
 payment_id uuid references public.cb_shared_payments on delete restrict,uploaded_by uuid not null references auth.users,
 bucket text not null default 'cb-documents' check(bucket='cb-documents'),path text not null,name text not null,
 kind text not null check(kind in ('Invoice','Receipt','Contract','Other')),created_at timestamptz not null default now(),removed_at timestamptz,removed_by uuid references auth.users,
 unique(expense_id,bucket,path)
);
alter table public.cb_expense_files enable row level security;
revoke all on public.cb_expense_files from public,anon,authenticated;
create index if not exists cb_expense_files_expense on public.cb_expense_files(expense_id) where removed_at is null;
create or replace function public.cb_expense_file_access(p_bucket text,p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_expense_files f join public.cb_shared_expenses e on e.id=f.expense_id where f.bucket=p_bucket and f.path=p_path and f.removed_at is null and public.cb_expense_user_access(auth.uid(),e.project_id,e.id));
$$;
drop policy if exists cb_expense_files_read on storage.objects;
create policy cb_expense_files_read on storage.objects for select to authenticated using(public.cb_expense_file_access(bucket_id,name));
create or replace function public.cb_list_expense_files(p_expense uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare pid uuid;
begin
 select project_id into pid from public.cb_shared_expenses where id=p_expense;
 if not public.cb_expense_user_access(auth.uid(),pid,p_expense) then raise exception 'Financial access required' using errcode='42501';end if;
 return jsonb_build_object('editable',public.cb_project_access(pid,'write'),'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at desc,f.id),'[]') from public.cb_expense_files f where f.expense_id=p_expense and f.removed_at is null));
end;$$;
create or replace function public.cb_link_expense_file(p_expense uuid,p_payment uuid,p_path text,p_name text,p_kind text) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;f public.cb_expense_files;meta jsonb;
begin
 select project_id into pid from public.cb_shared_expenses where id=p_expense;perform 1 from public.cb_projects where id=pid for update;
 if not coalesce(public.cb_expense_user_access(auth.uid(),pid,p_expense) and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 if p_path is null or split_part(p_path,'/',1)<>auth.uid()::text or p_path !~ '^[-a-zA-Z0-9_/\.]+$' or p_path like '%..%' then raise exception 'Upload your own file before attaching it';end if;
 select metadata into meta from storage.objects where bucket_id='cb-documents' and name=p_path;
 if not found then raise exception 'Upload your own file before attaching it';end if;
 if coalesce(meta->>'mimetype','') not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'Use a PDF, JPEG, PNG or WebP receipt';end if;
 if exists(select 1 from public.cb_file_reservations where bucket='cb-documents' and path=p_path and deleting) then raise exception 'File cleanup is in progress. Upload again.';end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 200 or coalesce(p_kind,'') not in ('Invoice','Receipt','Contract','Other') then raise exception 'Choose a file name and document type';end if;
 if p_payment is not null and not exists(select 1 from public.cb_shared_payments where id=p_payment and expense_id=p_expense) then raise exception 'Choose a payment from this expense';end if;
 select * into f from public.cb_expense_files where expense_id=p_expense and bucket='cb-documents' and path=p_path;
 if found then
  if f.payment_id is distinct from p_payment or f.name<>btrim(p_name) or f.kind<>p_kind then raise exception 'This file is already linked with different details' using errcode='PT409';end if;
  if f.removed_at is null then return to_jsonb(f);end if;
 end if;
 if (select count(*) from public.cb_expense_files where expense_id=p_expense and removed_at is null)>=20 then raise exception 'Keep up to twenty documents per expense';end if;
 insert into public.cb_expense_files(expense_id,payment_id,uploaded_by,path,name,kind) values(p_expense,p_payment,auth.uid(),p_path,btrim(p_name),p_kind)
 on conflict(expense_id,bucket,path) do update set removed_at=null,removed_by=null returning * into f;
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared financial document attached',array['finance']);return to_jsonb(f);
end;$$;
create or replace function public.cb_remove_expense_file(p_file uuid) returns void language plpgsql security definer set search_path='' as $$
declare f public.cb_expense_files;pid uuid;
begin
 select e.project_id into pid from public.cb_expense_files x join public.cb_shared_expenses e on e.id=x.expense_id where x.id=p_file;perform 1 from public.cb_projects where id=pid for update;
 select * into f from public.cb_expense_files where id=p_file;
 if not coalesce(public.cb_expense_user_access(auth.uid(),pid,f.expense_id) and public.cb_project_access(pid,'write'),false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 if f.removed_at is not null then return;end if;
 update public.cb_expense_files set removed_at=now(),removed_by=auth.uid() where id=f.id;
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared financial document removed',array['finance']);
end;$$;
do $migration$ begin
 if to_regprocedure('public.cb_file_referenced_before_expenses(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_expenses;end if;
end;$migration$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$
 select public.cb_file_referenced_before_expenses(p_bucket,p_path) or exists(select 1 from public.cb_expense_files where bucket=p_bucket and path=p_path and (removed_at is null or removed_at>now()-interval '30 days'));
$$;
revoke all on function public.cb_expense_file_access(text,text),public.cb_list_expense_files(uuid),public.cb_link_expense_file(uuid,uuid,text,text,text),public.cb_remove_expense_file(uuid),public.cb_file_referenced(text,text),public.cb_file_referenced_before_expenses(text,text) from public,anon,authenticated;
grant execute on function public.cb_expense_file_access(text,text),public.cb_list_expense_files(uuid),public.cb_link_expense_file(uuid,uuid,text,text,text),public.cb_remove_expense_file(uuid),public.cb_file_referenced(text,text) to authenticated;
do $refresh$
declare signature text;definition text;
begin
 foreach signature in array array['public.cb_claim_unused_files()','public.cb_file_delete_allowed(text,text)'] loop
 if to_regprocedure(signature) is not null then select pg_get_functiondef(to_regprocedure(signature)) into definition;execute definition;end if;
 end loop;
end;$refresh$;
notify pgrst,'reload schema';
commit;
