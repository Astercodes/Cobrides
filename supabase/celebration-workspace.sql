-- Run after wedding-projects.sql. Existing records are preserved.
begin;
create or replace function public.cb_save_project_event(p_project uuid,p_local_ref text,p_revision bigint,p_title text,p_details jsonb,p_visibility text default 'team')
returns public.cb_project_events language plpgsql security definer set search_path='' as $$
declare event public.cb_project_events; safe jsonb; date_value text; part text;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Celebration edit access denied';end if;
 if length(trim(coalesce(p_title,''))) not between 1 and 200 or length(coalesce(p_local_ref,'')) not between 1 and 300 or p_visibility not in ('team','restricted') or p_visibility is null or jsonb_typeof(p_details) is distinct from 'object' or octet_length(p_details::text)>20000 then raise exception 'Enter valid celebration details';end if;
 select coalesce(jsonb_object_agg(key,val),'{}') into safe from jsonb_each(p_details) x(key,val) where key in ('type','status','date','dateStatus','time','endTime','venue','dressCode','owner','logistics','program','menu');
 if exists(select 1 from jsonb_each(safe) x where jsonb_typeof(x.value)<>'string' or length(x.value#>>'{}')>4000) then raise exception 'Celebration details must be text, up to 4000 characters per field';end if;
 date_value:=safe->>'date';if coalesce(date_value,'')<>'' then if date_value !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Use a valid celebration date';end if;perform date_value::date;end if;
 if coalesce(safe->>'dateStatus','Projected') not in ('Projected','Tentative','Confirmed') then raise exception 'Choose a valid date status';end if;
 if safe->>'dateStatus'='Confirmed' and coalesce(date_value,'')='' then raise exception 'Choose a date before confirming this celebration';end if;
 if coalesce(safe->>'status','Draft') not in ('Draft','Venue booked','Confirmed','Completed') then raise exception 'Choose a valid celebration status';end if;
 foreach part in array array['time','endTime'] loop
  if coalesce(safe->>part,'')<>'' then if safe->>part !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Use a valid celebration time';end if;end if;
 end loop;
 if coalesce(safe->>'time','')<>'' and coalesce(safe->>'endTime','')<>'' and (safe->>'endTime')::time<=(safe->>'time')::time then raise exception 'End time must be after start time on the same day';end if;
 select * into event from public.cb_project_events where project_id=p_project and local_ref=p_local_ref for update;
 if coalesce(event.revision,0)<>p_revision then raise exception 'CB_PROJECT_CONFLICT: Refresh this celebration before saving.' using errcode='40001';end if;
 if event.id is null then insert into public.cb_project_events(project_id,local_ref,title,details,visibility) values(p_project,p_local_ref,trim(p_title),safe,p_visibility) returning * into event;
 else update public.cb_project_events set title=trim(p_title),details=safe,visibility=p_visibility,revision=revision+1,updated_at=now() where id=event.id returning * into event;end if;
 update public.cb_projects set revision=revision+1,updated_at=now() where id=p_project;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Celebration updated');return event;
end; $$;
revoke all on function public.cb_save_project_event(uuid,text,bigint,text,jsonb,text) from public,anon;
grant execute on function public.cb_save_project_event(uuid,text,bigint,text,jsonb,text) to authenticated;
notify pgrst,'reload schema';
commit;
