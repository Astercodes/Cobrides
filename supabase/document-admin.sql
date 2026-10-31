begin;
create or replace function public.cb_document_admin_catalog() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.cb_document_admin() then raise exception 'Template administrator required' using errcode='42501';end if;
 return jsonb_build_object('admin',true,'premium',true,'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by position),'[]') from public.cb_document_categories c),'templates',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'revision',t.revision,'official',t.official,'own',t.created_by=auth.uid(),'title',t.data->>'title','category',t.data->>'category','country',t.data->>'country','tier',t.data->>'tier','featured',t.data->'featured','status',t.data->>'status','description',t.data->>'description','uses',(select count(*) from public.cb_documents d where d.template_id=t.id)) order by t.data->>'title'),'[]') from public.cb_document_templates t where t.official),'documents','[]'::jsonb,'folders','[]'::jsonb,'events','[]'::jsonb,'people','[]'::jsonb,'references','[]'::jsonb);
end;$$;
revoke all on function public.cb_document_admin_catalog() from public,anon,authenticated;
grant execute on function public.cb_document_admin_catalog() to authenticated;
notify pgrst,'reload schema';commit;
