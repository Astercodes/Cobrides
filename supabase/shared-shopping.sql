-- Shared shopping is opt-in and separate from personal shopping and payment records.
begin;
create table if not exists public.cb_shopping_lists(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 title text not null,readers uuid[] not null default '{}',archived boolean not null default false,revision bigint not null default 1,created_by uuid not null references auth.users,updated_at timestamptz not null default now()
);
create table if not exists public.cb_shopping_items(
 id uuid primary key default gen_random_uuid(),list_id uuid not null references public.cb_shopping_lists on delete cascade,
 data jsonb not null,buyer_id uuid references auth.users,product_key text not null default '',
 status text not null default 'Needed',progress_note text not null default '',revision bigint not null default 1,created_by uuid not null references auth.users,updated_at timestamptz not null default now()
);
create unique index if not exists cb_shopping_product_unique on public.cb_shopping_items(list_id,product_key) where product_key<>'' and status<>'Cancelled';
create index if not exists cb_shopping_project on public.cb_shopping_lists(project_id);
create index if not exists cb_shopping_list_items on public.cb_shopping_items(list_id);
create table if not exists public.cb_shopping_cost_links(item_id uuid primary key references public.cb_shopping_items on delete cascade,expense_id uuid not null references public.cb_shared_expenses on delete restrict,revision bigint not null default 1);
create table if not exists public.cb_shopping_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_shopping_versions(kind text not null,target_id uuid not null,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(kind,target_id,revision));
alter table public.cb_shopping_lists enable row level security;alter table public.cb_shopping_items enable row level security;alter table public.cb_shopping_cost_links enable row level security;alter table public.cb_shopping_writes enable row level security;alter table public.cb_shopping_versions enable row level security;
revoke all on public.cb_shopping_lists,public.cb_shopping_items,public.cb_shopping_cost_links,public.cb_shopping_writes,public.cb_shopping_versions from public,anon,authenticated;
create or replace function public.cb_shopping_access(p_list uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_shopping_lists l where l.id=p_list and public.cb_project_access(l.project_id,'read') and (public.cb_project_access(l.project_id,'owner') or public.cb_project_access(l.project_id,'write') or auth.uid()=any(l.readers)));
$$;
create or replace function public.cb_shopping_workspace(p_project uuid,p_list uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare manager boolean;financial boolean;chosen uuid;
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding shopping access denied' using errcode='42501';end if;
 manager=public.cb_project_access(p_project,'write');financial=public.cb_project_access(p_project,'finance');
 if p_list is not null and not exists(select 1 from public.cb_shopping_lists where id=p_list and project_id=p_project and public.cb_shopping_access(id)) then raise exception 'Shopping list access denied' using errcode='42501';end if;
 chosen=coalesce(p_list,(select id from public.cb_shopping_lists where project_id=p_project and public.cb_shopping_access(id) order by archived,updated_at desc,id limit 1));
 return jsonb_build_object('project',p_project,'selected',chosen,'editable',manager,'active',exists(select 1 from public.cb_projects where id=p_project and archived_at is null),'finance',financial,
 'people',case when manager then (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(p.full_name,''),u.email),'can_manage',public.cb_collab_user_access(u.id,p_project,'write') or public.cb_collab_user_access(u.id,p_project,'owner'))),'[]') from auth.users u left join public.cb_profiles p on p.user_id=u.id where u.id in (select owner_id from public.cb_projects where id=p_project union select user_id from public.cb_members where project_id=p_project) and public.cb_collab_user_access(u.id,p_project,'read')) else '[]'::jsonb end,
 'expenses',case when financial then (select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title)),'[]') from public.cb_shared_expenses where project_id=p_project) else '[]'::jsonb end,
 'lists',(select coalesce(jsonb_agg(to_jsonb(l) order by l.updated_at desc,l.id),'[]') from public.cb_shopping_lists l where l.project_id=p_project and public.cb_shopping_access(l.id)),
 'items',(select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('buyer_name',(select coalesce(nullif(p.full_name,''),u.email) from auth.users u left join public.cb_profiles p on p.user_id=u.id where u.id=i.buyer_id),
 'can_update',not l.archived and exists(select 1 from public.cb_projects where id=p_project and archived_at is null) and (manager or i.buyer_id=auth.uid() and i.status not in ('Refunded','Cancelled')),
 'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'status',h.snapshot->>'status','note',h.snapshot->>'progress_note','at',h.at) order by h.revision desc),'[]') from public.cb_shopping_versions h where h.kind='item' and h.target_id=i.id))||case when financial then jsonb_build_object('cost_link',(select to_jsonb(c) from public.cb_shopping_cost_links c where item_id=i.id)) else '{}'::jsonb end order by i.updated_at desc,i.id),'[]') from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id where l.project_id=p_project and l.id=chosen and public.cb_shopping_access(l.id)));
end;$$;
create or replace function public.cb_save_shopping_list(p_project uuid,p_id uuid,p_revision bigint,p_client uuid,p_title text,p_readers uuid[],p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.cb_shopping_lists;prev public.cb_shopping_writes;payload jsonb;result jsonb;person uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Shopping planning access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','list','project',p_project,'id',p_id,'revision',p_revision,'title',p_title,'readers',p_readers,'archived',p_archived);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_shopping_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if length(btrim(coalesce(p_title,''))) not between 1 and 160 or p_readers is null or cardinality(p_readers)>100 or p_archived is null then raise exception 'Check list title and audience';end if;
 foreach person in array p_readers loop if person is null or not public.cb_collab_user_access(person,p_project,'read') then raise exception 'Choose accepted wedding teammates';end if;end loop;
 if p_id is null then
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating a list' using errcode='PT409';end if;
 if (select count(*) from public.cb_shopping_lists where project_id=p_project)>=100 then raise exception 'This wedding has reached its shared-list allowance';end if;
 insert into public.cb_shopping_lists(project_id,title,readers,archived,created_by) values(p_project,btrim(p_title),p_readers,p_archived,auth.uid()) returning * into l;
 else
 select * into l from public.cb_shopping_lists where id=p_id and project_id=p_project;
 if not found then raise exception 'Shopping list unavailable' using errcode='42501';end if;
 if l.revision is distinct from p_revision then raise exception 'Shopping list changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_shopping_lists set title=btrim(p_title),readers=p_readers,archived=p_archived,revision=revision+1,updated_at=now() where id=l.id returning * into l;
 end if;
 result=to_jsonb(l);insert into public.cb_shopping_versions values('list',l.id,l.revision,auth.uid(),result,now());insert into public.cb_shopping_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_save_shopping_item(p_list uuid,p_id uuid,p_revision bigint,p_client uuid,p_buyer uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.cb_shopping_lists;i public.cb_shopping_items;prev public.cb_shopping_writes;payload jsonb;result jsonb;k text;val text;product text;
begin
 select * into l from public.cb_shopping_lists where id=p_list;perform 1 from public.cb_projects where id=l.project_id for update;select * into l from public.cb_shopping_lists where id=p_list;
 if not coalesce(public.cb_shopping_access(l.id) and public.cb_project_access(l.project_id,'write') and not l.archived,false) then raise exception 'Shopping planning access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','item','list',p_list,'id',p_id,'revision',p_revision,'buyer',p_buyer,'data',p_data);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_shopping_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>15000 or p_data-array['title','category','merchant','url','image','variant','quantity','due','deliveryDue','returnDue','notes','priority']::text[]<>'{}' then raise exception 'Check shopping item fields';end if;
 for k,val in select key,value #>> '{}' from jsonb_each(p_data) loop if jsonb_typeof(p_data->k)<>'string' or length(val)>(case when k in ('notes','url','image') then 3000 else 500 end) then raise exception 'Shopping fields must be text within their limits';end if;end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 200 or coalesce(p_data->>'quantity','') !~ '^[1-9][0-9]{0,3}$' or coalesce(p_data->>'priority','Required') not in ('Required','Optional') then raise exception 'Add a title and quantity from 1 to 9999';end if;
 foreach k in array array['url','image'] loop val=coalesce(p_data->>k,'');if val<>'' and (val !~ '^https://[^/?#[:space:]]+([/?#]|$)' or val ~ '^https://[^/]*@' or val ~ '[[:space:]]') then raise exception 'Use secure HTTPS product and image links without login details';end if;end loop;
 foreach k in array array['due','deliveryDue','returnDue'] loop val=coalesce(p_data->>k,'');if val<>'' then if val !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose valid shopping dates';end if;perform val::date;end if;end loop;
 if p_buyer is not null and not (public.cb_collab_user_access(p_buyer,l.project_id,'read') and (p_buyer=any(l.readers) or public.cb_collab_user_access(p_buyer,l.project_id,'write') or public.cb_collab_user_access(p_buyer,l.project_id,'owner'))) then raise exception 'Choose an accepted buyer with access to this list';end if;
 product=regexp_replace(coalesce(p_data->>'url',''),'#.*$','');
 if product ~* '^https://(www\.)?amazon\.[a-z.]+/(.*/)?(dp|gp/product)/[a-z0-9]{10}([/?]|$)' then product='amazon:'||upper(substring(product from '(?i)/(?:dp|gp/product)/([a-z0-9]{10})'));end if;
 if product<>'' then product=encode(sha256(convert_to(product,'UTF8')),'hex');end if;
 if product<>'' and exists(select 1 from public.cb_shopping_items where list_id=l.id and product_key=product and status<>'Cancelled' and (p_id is null or id<>p_id)) then raise exception 'This product is already on this list. Review the existing item before buying.' using errcode='PT409';end if;
 if p_id is null then
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before adding an item' using errcode='PT409';end if;
 if (select count(*) from public.cb_shopping_items where list_id=l.id)>=200 then raise exception 'This list has reached its item allowance';end if;
 insert into public.cb_shopping_items(list_id,data,buyer_id,product_key,created_by) values(l.id,p_data,p_buyer,product,auth.uid()) returning * into i;
 else
 select * into i from public.cb_shopping_items where id=p_id and list_id=l.id;
 if not found then raise exception 'Shopping item unavailable' using errcode='42501';end if;
 if i.revision is distinct from p_revision then raise exception 'Shopping item changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_shopping_items set data=p_data,buyer_id=p_buyer,product_key=product,revision=revision+1,updated_at=now() where id=i.id returning * into i;
 end if;
 result=to_jsonb(i);insert into public.cb_shopping_versions values('item',i.id,i.revision,auth.uid(),result,now());insert into public.cb_shopping_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(l.project_id,auth.uid(),'Shared shopping item reviewed',array['shopping']);return result;
end;$$;
create or replace function public.cb_update_shopping_status(p_item uuid,p_revision bigint,p_client uuid,p_status text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.cb_shopping_items;l public.cb_shopping_lists;prev public.cb_shopping_writes;payload jsonb;result jsonb;manager boolean;
begin
 select l2.* into l from public.cb_shopping_items i2 join public.cb_shopping_lists l2 on l2.id=i2.list_id where i2.id=p_item;perform 1 from public.cb_projects where id=l.project_id for update;select * into l from public.cb_shopping_lists where id=l.id;select * into i from public.cb_shopping_items where id=p_item;manager=public.cb_project_access(l.project_id,'write');
 if not coalesce(public.cb_shopping_access(l.id) and not l.archived and exists(select 1 from public.cb_projects where id=l.project_id and archived_at is null) and (manager or i.buyer_id=auth.uid()),false) then raise exception 'Assigned shopping access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','status','item',p_item,'revision',p_revision,'status',p_status,'note',p_note);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_shopping_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if i.revision is distinct from p_revision then raise exception 'Shopping item changed. Refresh before updating.' using errcode='PT409';end if;
 if coalesce(p_status,'') not in ('Needed','Reserved','Purchased','Shipped','Delivered','Return requested','Returned','Refunded','Cancelled') or p_note is null or length(p_note)>2000 or length(btrim(p_note))=0 then raise exception 'Choose a valid status and add a progress note';end if;
 if not manager and not (case i.status when 'Needed' then p_status in ('Reserved','Purchased') when 'Reserved' then p_status in ('Needed','Purchased') when 'Purchased' then p_status in ('Shipped','Delivered','Return requested') when 'Shipped' then p_status in ('Delivered','Return requested') when 'Delivered' then p_status='Return requested' when 'Return requested' then p_status='Returned' when 'Returned' then p_status='Refunded' else false end) then raise exception 'This status change needs your wedding planner';end if;
 if p_status<>'Cancelled' and exists(select 1 from public.cb_shopping_items where list_id=l.id and product_key=i.product_key and i.product_key<>'' and status<>'Cancelled' and id<>i.id) then raise exception 'This product is already active on this list' using errcode='PT409';end if;
 update public.cb_shopping_items set status=p_status,progress_note=btrim(p_note),revision=revision+1,updated_at=now() where id=i.id returning * into i;
 result=to_jsonb(i);insert into public.cb_shopping_versions values('item',i.id,i.revision,auth.uid(),result,now());insert into public.cb_shopping_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(l.project_id,auth.uid(),'Shared shopping progress updated',array['shopping']);return result;
end;$$;
create or replace function public.cb_link_shopping_expense(p_item uuid,p_revision bigint,p_client uuid,p_expense uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.cb_shopping_items;l public.cb_shopping_lists;c public.cb_shopping_cost_links;prev public.cb_shopping_writes;payload jsonb;result jsonb;
begin
 select l2.* into l from public.cb_shopping_items i2 join public.cb_shopping_lists l2 on l2.id=i2.list_id where i2.id=p_item;perform 1 from public.cb_projects where id=l.project_id for update;select * into l from public.cb_shopping_lists where id=l.id;
 if not coalesce(public.cb_shopping_access(l.id) and public.cb_project_access(l.project_id,'write') and public.cb_project_access(l.project_id,'finance') and not l.archived,false) then raise exception 'Planning and financial access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','cost','item',p_item,'revision',p_revision,'expense',p_expense);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_shopping_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into i from public.cb_shopping_items where id=p_item;
 if i.revision is distinct from p_revision then raise exception 'Shopping item changed. Refresh before linking.' using errcode='PT409';end if;
 if p_expense is null or not exists(select 1 from public.cb_shared_expenses where id=p_expense and project_id=l.project_id) then raise exception 'Choose an expense from this wedding';end if;
 insert into public.cb_shopping_cost_links values(i.id,p_expense,1) on conflict(item_id) do update set expense_id=excluded.expense_id,revision=cb_shopping_cost_links.revision+1 returning * into c;
 update public.cb_shopping_items set revision=revision+1,updated_at=now() where id=i.id returning * into i;
 insert into public.cb_shopping_versions values('item',i.id,i.revision,auth.uid(),to_jsonb(i),now());
 insert into public.cb_shopping_versions values('cost',i.id,c.revision,auth.uid(),to_jsonb(c),now());
 result=to_jsonb(c);insert into public.cb_shopping_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_shopping_access(uuid),public.cb_shopping_workspace(uuid,uuid),public.cb_save_shopping_list(uuid,uuid,bigint,uuid,text,uuid[],boolean),public.cb_save_shopping_item(uuid,uuid,bigint,uuid,uuid,jsonb),public.cb_update_shopping_status(uuid,bigint,uuid,text,text),public.cb_link_shopping_expense(uuid,bigint,uuid,uuid) from public,anon,authenticated;
grant execute on function public.cb_shopping_workspace(uuid,uuid),public.cb_save_shopping_list(uuid,uuid,bigint,uuid,text,uuid[],boolean),public.cb_save_shopping_item(uuid,uuid,bigint,uuid,uuid,jsonb),public.cb_update_shopping_status(uuid,bigint,uuid,text,text),public.cb_link_shopping_expense(uuid,bigint,uuid,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
