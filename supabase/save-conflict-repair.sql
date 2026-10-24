-- PostgREST 14 retries SQLSTATE 40001 indefinitely. Application revision conflicts
-- must return HTTP 409 (PT409), preserving all conflict checks and wedding records.
begin;
do $repair$
declare fn record; definition text;
begin
 for fn in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' and left(p.proname,3)='cb_' loop
  definition=pg_get_functiondef(fn.oid);
  if position('''40001''' in definition)>0 and position('CONFLICT' in definition)>0 then
   execute replace(definition,'''40001''','''PT409''');
  end if;
 end loop;
end; $repair$;
notify pgrst,'reload schema';
commit;
