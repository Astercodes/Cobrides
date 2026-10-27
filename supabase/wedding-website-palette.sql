-- Allow only validated HEX colours on published wedding websites.
begin;
do $$begin
 if to_regprocedure('public.cb_validate_wedding_site_base(jsonb)') is null then alter function public.cb_validate_wedding_site(jsonb) rename to cb_validate_wedding_site_base;end if;
end;$$;
create or replace function public.cb_validate_wedding_site(p_data jsonb) returns void language plpgsql stable set search_path='' as $$
declare c jsonb;
begin
 perform public.cb_validate_wedding_site_base(p_data-'customPalette');
 if p_data ? 'customPalette' then
 if jsonb_typeof(p_data->'customPalette') is distinct from 'array' then raise exception 'Choose a valid website colour palette';end if;
 if jsonb_array_length(p_data->'customPalette') not between 2 and 8 then raise exception 'Choose between two and eight website colours';end if;
 for c in select value from jsonb_array_elements(p_data->'customPalette') loop if jsonb_typeof(c)<>'string' or c#>>'{}' !~* '^#[a-f0-9]{6}$' then raise exception 'Use valid HEX colours in your website palette';end if;end loop;
 end if;
end;$$;
revoke all on function public.cb_validate_wedding_site_base(jsonb),public.cb_validate_wedding_site(jsonb) from public,anon,authenticated;
do $$begin execute pg_get_functiondef('public.cb_save_wedding_site(uuid,bigint,uuid,jsonb)'::regprocedure);execute pg_get_functiondef('public.cb_set_wedding_publication(uuid,bigint,uuid,text)'::regprocedure);end;$$;
notify pgrst,'reload schema';
commit;
