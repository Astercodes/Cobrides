-- Fill missing countdown dates in older published websites from the saved wedding date.
begin;
create or replace function public.cb_wedding_countdown_view(p_site jsonb,p_date text) returns jsonb language plpgsql stable set search_path='' as $$
begin
 if p_site is null or exists(select 1 from jsonb_array_elements(coalesce(p_site->'events','[]')) e where coalesce(e->>'date','')<>'') then return p_site;end if;
 if coalesce(p_date,'') !~ '^\d{4}-\d{2}-\d{2}$' then return p_site;end if;
 begin perform p_date::date;exception when others then return p_site;end;
 return p_site||jsonb_build_object('countdownEvent','Wedding day','events',jsonb_build_array(jsonb_build_object('title','Wedding day','date',p_date,'time','00:00','timeZone','UTC','venue',''))||coalesce(p_site->'events','[]'));
end;$$;
create or replace function public.cb_read_wedding_site(p_token text) returns jsonb language sql stable security definer set search_path='' as $$
 select public.cb_wedding_countdown_view(s.published,p.details->>'date') from public.cb_wedding_sites s join public.cb_projects p on p.id=s.project_id where length(p_token)=64 and p_token ~ '^[a-f0-9]{64}$' and s.public_token=p_token and s.published is not null and p.archived_at is null;
$$;
create or replace function public.cb_read_wedding_slug(p_slug text) returns jsonb language sql stable security definer set search_path='' as $$
 select public.cb_wedding_countdown_view(s.published,p.details->>'date') from public.cb_wedding_sites s join public.cb_projects p on p.id=s.project_id where length(p_slug) between 2 and 82 and p_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and s.public_slug=p_slug and s.published is not null and p.archived_at is null;
$$;
revoke all on function public.cb_wedding_countdown_view(jsonb,text),public.cb_read_wedding_site(text),public.cb_read_wedding_slug(text) from public,anon,authenticated;
grant execute on function public.cb_read_wedding_site(text),public.cb_read_wedding_slug(text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
