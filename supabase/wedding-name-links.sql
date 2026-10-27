-- Readable wedding-name links. Run after wedding-publication.sql.
begin;
alter table public.cb_wedding_sites add column if not exists public_slug text;
create unique index if not exists cb_wedding_sites_slug on public.cb_wedding_sites(public_slug) where public_slug is not null;
-- Reserve historical names so an old invitation cannot open another couple's website.
create table if not exists public.cb_wedding_slug_names(slug text primary key,project_id uuid not null);
alter table public.cb_wedding_slug_names enable row level security;
revoke all on public.cb_wedding_slug_names from public,anon,authenticated;
create or replace function public.cb_allocate_wedding_slug(p_project uuid,p_replace boolean default false) returns text language plpgsql security definer set search_path='' as $$
declare s public.cb_wedding_sites;base text;candidate text;n integer=1;
begin
 perform pg_advisory_xact_lock(752104338);
 select * into s from public.cb_wedding_sites where project_id=p_project;
 if not found then raise exception 'Save a wedding website first';end if;
 if s.public_slug is not null and not p_replace then return s.public_slug;end if;
 base=lower(coalesce(s.published->>'names',s.draft->>'names','our wedding'));
 base=translate(base,'àáâãäåèéêëìíîïòóôõöùúûüñçýÿ','aaaaaaeeeeiiiiooooouuuuncyy');
 base=replace(base,'&',' and ');base=regexp_replace(base,'[^a-z0-9]+','-','g');base=trim(both '-' from left(base,70));if length(base)<2 then base='our-wedding';end if;
 candidate=base;
 while exists(select 1 from public.cb_wedding_slug_names where slug=candidate) loop n=n+1;candidate=base||'-'||n::text;end loop;
 insert into public.cb_wedding_slug_names values(candidate,p_project);return candidate;
end;$$;
-- Give existing websites a readable name without changing their content or old token links.
do $$declare r record;begin for r in select project_id from public.cb_wedding_sites where public_slug is null order by updated_at,project_id loop update public.cb_wedding_sites set public_slug=public.cb_allocate_wedding_slug(r.project_id) where project_id=r.project_id;end loop;end;$$;
do $$declare definition text;begin
 definition=pg_get_functiondef('public.cb_wedding_publication(uuid)'::regprocedure);
 if position($needle$'slug'$needle$ in definition)=0 then
 definition=replace(definition,$needle$'token',case$needle$, $replacement$'slug',case when s.published is not null then s.public_slug else null end,'token',case$replacement$);execute definition;
 end if;
 definition=pg_get_functiondef('public.cb_set_wedding_publication(uuid,bigint,uuid,text)'::regprocedure);
 if position('cb_allocate_wedding_slug' in definition)=0 then
 definition=replace(definition,'set published=draft,published_at=now()','set published=draft,published_at=now(),public_slug=public.cb_allocate_wedding_slug(p_project)');
 definition=replace(definition,'set public_token=replace(gen_random_uuid()', 'set public_slug=public.cb_allocate_wedding_slug(p_project,true),public_token=replace(gen_random_uuid()');execute definition;
 end if;
end;$$;
create or replace function public.cb_read_wedding_slug(p_slug text) returns jsonb language sql stable security definer set search_path='' as $$
 select s.published from public.cb_wedding_sites s join public.cb_projects p on p.id=s.project_id where length(p_slug) between 2 and 82 and p_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and s.public_slug=p_slug and s.published is not null and p.archived_at is null;
$$;
revoke all on function public.cb_allocate_wedding_slug(uuid,boolean),public.cb_read_wedding_slug(text) from public,anon,authenticated;
grant execute on function public.cb_read_wedding_slug(text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
