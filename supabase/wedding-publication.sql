-- Hosted wedding websites: explicit, owner-approved publication.
-- Run after collaboration-access.sql and wedding-projects.sql.
begin;
create table if not exists public.cb_wedding_sites(
 project_id uuid primary key references public.cb_projects on delete cascade,
 draft jsonb not null,published jsonb,public_token text not null unique default replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),
 published_at timestamptz,revision bigint not null default 1,updated_at timestamptz not null default now(),updated_by uuid not null references auth.users
);
create table if not exists public.cb_wedding_site_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
alter table public.cb_wedding_sites enable row level security;alter table public.cb_wedding_site_writes enable row level security;
revoke all on public.cb_wedding_sites,public.cb_wedding_site_writes from public,anon,authenticated;
create or replace function public.cb_website_url(v text) returns boolean language sql immutable set search_path='' as $$select coalesce(length(v)<=3000 and v ~ '^https://[^/@?#[:space:]]+(/[^[:space:]]*)?$' and v !~* '/storage/v1/' and v !~ '[<>"\\]',false)$$;
create or replace function public.cb_website_image(v text) returns boolean language sql immutable set search_path='' as $$select coalesce(v='' or v ~ '^assets/(wedding|proposal|retreat|honeymoon|planning)\.webp$' or (length(v)<1450000 and v ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') or public.cb_website_url(v),false)$$;
create or replace function public.cb_validate_wedding_site(p_data jsonb) returns void language plpgsql stable set search_path='' as $$
declare k text;v jsonb;r jsonb;d text;
begin
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>4000000 or p_data-array['version','countdownEvent','names','story','announcement','dress','travel','faq','language','cover','gallery','events','registry','rsvpUrl','replyEmail','theme']::text[]<>'{}' then raise exception 'Review the website fields and keep shared photos below 4 MB';end if;
 foreach k in array array['countdownEvent','names','story','announcement','dress','travel','faq','language','cover','rsvpUrl','replyEmail','theme'] loop
 if jsonb_typeof(p_data->k) is distinct from 'string' then raise exception 'Complete the website text fields';end if;
 if k<>'cover' and length(p_data->>k)>3000 then raise exception 'Website text is too long';end if;end loop;
 if length(btrim(p_data->>'names')) not between 1 and 120 or p_data->>'language' not in ('English','French') or p_data->>'theme' not in ('Jewel garden','Coastal romance','Modern editorial') or p_data->'version' is distinct from '1'::jsonb then raise exception 'Check the couple names, language and website design';end if;
 if not public.cb_website_image(p_data->>'cover') or p_data->>'rsvpUrl'<>'' and not public.cb_website_url(p_data->>'rsvpUrl') or p_data->>'replyEmail'<>'' and (length(p_data->>'replyEmail')>160 or p_data->>'replyEmail' !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+\.[^[:space:]<>@]+$') then raise exception 'Review website images and reply details';end if;
 foreach k in array array['gallery','events','registry'] loop if jsonb_typeof(p_data->k) is distinct from 'array' then raise exception 'Review website photographs, celebrations and registry';end if;end loop;
 if jsonb_array_length(p_data->'gallery')>3 or jsonb_array_length(p_data->'events')>12 or jsonb_array_length(p_data->'registry')>60 then raise exception 'Too many website photographs, celebrations or gifts';end if;
 for v in select value from jsonb_array_elements(p_data->'gallery') loop if jsonb_typeof(v)<>'string' or not public.cb_website_image(v#>>'{}') then raise exception 'Use a supported public photograph';end if;end loop;
 for r in select value from jsonb_array_elements(p_data->'events') loop
 if jsonb_typeof(r)<>'object' or r-array['title','date','time','timeZone','venue']::text[]<>'{}' then raise exception 'Only public celebration details can be included';end if;
 foreach k in array array['title','date','time','timeZone','venue'] loop if jsonb_typeof(r->k) is distinct from 'string' or length(r->>k)>300 then raise exception 'Review celebration text';end if;end loop;
 d=r->>'date';if d<>'' then if d !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid celebration date';end if;perform d::date;end if;
 if r->>'time'<>'' and r->>'time' !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Choose a valid celebration time';end if;
 if r->>'timeZone'<>'' and not exists(select 1 from pg_timezone_names where name=r->>'timeZone') then raise exception 'Choose a valid celebration time zone';end if;
 end loop;
 for r in select value from jsonb_array_elements(p_data->'registry') loop
 if jsonb_typeof(r)<>'object' or r-array['title','description','kind','category','merchant','url','image','currency','reserved','target']::text[]<>'{}' then raise exception 'Only public gift details can be included';end if;
 foreach k in array array['title','description','kind','category','merchant','url','image','currency'] loop if jsonb_typeof(r->k) is distinct from 'string' or k<>'image' and length(r->>k)>3000 then raise exception 'Review public gift details';end if;end loop;
 if not public.cb_website_image(r->>'image') or r->>'url'<>'' and not public.cb_website_url(r->>'url') or r->>'currency' !~ '^[A-Z]{3}$' then raise exception 'Review gift images, links and currency';end if;
 foreach k in array array['reserved','target'] loop if jsonb_typeof(r->k) is distinct from 'number' or (r->>k)::numeric<0 or (r->>k)::numeric>1000000000000 then raise exception 'Review gift quantities';end if;end loop;
 end loop;
end;$$;
create or replace function public.cb_wedding_publication(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s public.cb_wedding_sites;
begin
 if not public.cb_project_access(p_project,'write') and not public.cb_project_access(p_project,'owner') then raise exception 'Wedding website management access required' using errcode='42501';end if;
 select * into s from public.cb_wedding_sites where project_id=p_project;
 return jsonb_build_object('project',p_project,'revision',coalesce(s.revision,0),'draft',s.draft,'live',s.published is not null,'token',case when s.published is not null then s.public_token else null end,'published_at',s.published_at,'unpublished_changes',s.draft is distinct from s.published,'owner',public.cb_project_access(p_project,'owner'),'active',exists(select 1 from public.cb_projects where id=p_project and archived_at is null));
end;$$;
create or replace function public.cb_save_wedding_site(p_project uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.cb_wedding_sites;prev public.cb_wedding_site_writes;payload jsonb;result jsonb;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Wedding website edit access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','draft','project',p_project,'revision',p_revision,'data',p_data);if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_wedding_site_writes where user_id=auth.uid() and client_id=p_client;if found then if prev.payload is distinct from payload then raise exception 'The draft changed during retry' using errcode='PT409';end if;return prev.response;end if;
 perform public.cb_validate_wedding_site(p_data);select * into s from public.cb_wedding_sites where project_id=p_project;
 if coalesce(s.revision,0) is distinct from p_revision then raise exception 'Website changed. Refresh before saving.' using errcode='PT409';end if;
 insert into public.cb_wedding_sites(project_id,draft,updated_by) values(p_project,p_data,auth.uid()) on conflict(project_id) do update set draft=excluded.draft,revision=cb_wedding_sites.revision+1,updated_at=now(),updated_by=auth.uid();
 result=public.cb_wedding_publication(p_project);insert into public.cb_wedding_site_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Wedding website draft saved',array['website']);return result;
end;$$;
create or replace function public.cb_set_wedding_publication(p_project uuid,p_revision bigint,p_client uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.cb_wedding_sites;prev public.cb_wedding_site_writes;payload jsonb;result jsonb;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'owner') or not exists(select 1 from public.cb_projects where id=p_project and archived_at is null) then raise exception 'The wedding owner must approve publication changes' using errcode='42501';end if;
 payload=jsonb_build_object('action',p_action,'project',p_project,'revision',p_revision);if p_client is null then raise exception 'Save request ID required';end if;
 select * into prev from public.cb_wedding_site_writes where user_id=auth.uid() and client_id=p_client;if found then if prev.payload is distinct from payload then raise exception 'Publication changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if p_action is null or p_action not in ('publish','unpublish','rotate') then raise exception 'Choose a publication action';end if;
 select * into s from public.cb_wedding_sites where project_id=p_project;if not found or s.revision is distinct from p_revision then raise exception 'Website changed. Refresh before publishing.' using errcode='PT409';end if;
 if p_action='publish' then perform public.cb_validate_wedding_site(s.draft);update public.cb_wedding_sites set published=draft,published_at=now() where project_id=p_project;
 elsif p_action='unpublish' then update public.cb_wedding_sites set published=null,published_at=null where project_id=p_project;
 else if s.published is null then raise exception 'Publish the website before replacing its link';end if;update public.cb_wedding_sites set public_token=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','') where project_id=p_project;end if;
 update public.cb_wedding_sites set revision=revision+1,updated_at=now(),updated_by=auth.uid() where project_id=p_project;result=public.cb_wedding_publication(p_project);
 insert into public.cb_wedding_site_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Wedding website publication updated',array['website']);return result;
end;$$;
create or replace function public.cb_read_wedding_site(p_token text) returns jsonb language sql stable security definer set search_path='' as $$
 select s.published from public.cb_wedding_sites s join public.cb_projects p on p.id=s.project_id where length(p_token)=64 and p_token ~ '^[a-f0-9]{64}$' and s.public_token=p_token and s.published is not null and p.archived_at is null;
$$;
revoke all on function public.cb_website_url(text),public.cb_website_image(text),public.cb_validate_wedding_site(jsonb),public.cb_wedding_publication(uuid),public.cb_save_wedding_site(uuid,bigint,uuid,jsonb),public.cb_set_wedding_publication(uuid,bigint,uuid,text),public.cb_read_wedding_site(text) from public,anon,authenticated;
grant execute on function public.cb_wedding_publication(uuid),public.cb_save_wedding_site(uuid,bigint,uuid,jsonb),public.cb_set_wedding_publication(uuid,bigint,uuid,text) to authenticated;
grant execute on function public.cb_read_wedding_site(text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
