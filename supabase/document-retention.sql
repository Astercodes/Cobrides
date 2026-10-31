begin;
create or replace function public.cb_purge_expired_documents() returns integer language plpgsql security definer set search_path='' as $$
declare r record;n integer=0;
begin
 for r in select id from public.cb_documents where deleted_at<=now()-interval '30 days' for update skip locked loop
  delete from public.cb_document_writes w where w.payload->>'doc'=r.id::text or w.response->>'id'=r.id::text;
  delete from public.cb_documents where id=r.id;n=n+1;
 end loop;return n;
end;$$;
revoke all on function public.cb_purge_expired_documents() from public,anon,authenticated;
do $cron$ begin if exists(select 1 from pg_extension where extname='pg_cron') then perform cron.schedule('cb-document-recovery-expiry','25 3 * * *','select public.cb_purge_expired_documents();');end if;end;$cron$;
notify pgrst,'reload schema';commit;
