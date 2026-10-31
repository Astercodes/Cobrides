-- Selective sharing of a saved private song into the native team playlist.
begin;
create table if not exists public.cb_experience_song_imports(user_id uuid not null references auth.users on delete cascade,scope text not null check(scope in ('personal','demo')),project_ref text not null,record_ref text not null,event_id uuid not null references public.cb_project_events on delete cascade,track_id uuid not null unique,source_hash text not null,created_at timestamptz not null default now(),primary key(user_id,scope,project_ref,record_ref,event_id));
create table if not exists public.cb_experience_song_import_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
alter table public.cb_experience_song_imports enable row level security;alter table public.cb_experience_song_import_writes enable row level security;revoke all on public.cb_experience_song_imports,public.cb_experience_song_import_writes from public,anon,authenticated;
create or replace function public.cb_experience_song_source(p_scope text,p_project text,p_ref text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p jsonb;r jsonb;pid uuid;begin
 if auth.uid() is null or p_scope is null or p_scope not in ('personal','demo') or length(coalesce(p_project,'')) not between 1 and 200 or length(coalesce(p_ref,'')) not between 1 and 200 then raise exception 'Open your own saved experience plan' using errcode='42501';end if;
 select body->'value' into p from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_project and (body->'path'=jsonb_build_array(p_scope,'projects') or p_scope='personal' and body->'path'=jsonb_build_array('projects')) order by jsonb_array_length(body->'path') desc limit 1;
 select body->'value' into r from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_ref and (body->'path'=jsonb_build_array(p_scope,'experienceSongs') or p_scope='personal' and body->'path'=jsonb_build_array('experienceSongs')) order by jsonb_array_length(body->'path') desc limit 1;
 if p is null or r is null or r->>'projectId' is distinct from p_project or coalesce(p->>'archived','false')='true' or coalesce(p->>'archiveStatus','') like 'Archived%' or coalesce(r->>'archived','false')='true' then raise exception 'Open your own active experience record first' using errcode='42501';end if;
 if coalesce(p->>'sharedProjectId','')!~'^[a-fA-F0-9-]{36}$' then raise exception 'Connect this wedding to its team workspace first';end if;pid=(p->>'sharedProjectId')::uuid;
 if not coalesce(public.cb_project_access(pid,'write'),false) then raise exception 'Planning access is required to share this record' using errcode='42501';end if;
 return jsonb_build_object('project',pid,'hash',md5(r::text),'data',jsonb_build_object('title',coalesce(r->>'title',''),'artist',coalesce(r->>'artist',''),'moment',coalesce(r->>'moment',''),'time',coalesce(r->>'time',''),'url','','instructions','','list','Play'));end;$$;
create or replace function public.cb_experience_song_preview(p_scope text,p_project text,p_ref text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare src jsonb;pid uuid;
begin
 src=public.cb_experience_song_source(p_scope,p_project,p_ref);pid=(src->>'project')::uuid;
 return src||jsonb_build_object('events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'revision',e.revision,'playlist_revision',coalesce(p.revision,0)) order by e.details->>'date',e.title,e.id),'[]') from public.cb_project_events e left join public.cb_experience_playlists p on p.event_id=e.id where e.project_id=pid and public.cb_experience_member(e.id,auth.uid())),'shared',(select coalesce(jsonb_agg(jsonb_build_object('event',l.event_id,'track',l.track_id,'source_changed',l.source_hash is distinct from src->>'hash','present',exists(select 1 from public.cb_experience_playlists p cross join lateral jsonb_array_elements(p.tracks) t where p.event_id=l.event_id and t->>'id'=l.track_id::text))),'[]') from public.cb_experience_song_imports l join public.cb_project_events e on e.id=l.event_id where l.user_id=auth.uid() and l.scope=p_scope and l.project_ref=p_project and l.record_ref=p_ref and e.project_id=pid and public.cb_experience_member(e.id,auth.uid())));
end;$$;
create or replace function public.cb_share_experience_song(p_scope text,p_project text,p_ref text,p_event uuid,p_event_revision bigint,p_playlist_revision bigint,p_source_hash text,p_client uuid,p_data jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_project_events;src jsonb;w public.cb_experience_song_import_writes;l public.cb_experience_song_imports;p public.cb_experience_playlists;payload jsonb;result jsonb;track uuid;written jsonb;
begin
 select * into e from public.cb_project_events where id=p_event;perform 1 from public.cb_projects where id=e.project_id for update;perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 src=public.cb_experience_song_source(p_scope,p_project,p_ref);select * into e from public.cb_project_events where id=p_event for update;
 if e.id is null or e.project_id::text is distinct from src->>'project' or not coalesce(public.cb_experience_member(e.id,auth.uid()),false) then raise exception 'Choose an accessible celebration in this wedding' using errcode='42501';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'ref',p_ref,'event',p_event,'event_revision',p_event_revision,'playlist_revision',p_playlist_revision,'hash',p_source_hash,'data',p_data,'confirm',p_confirm);
 if p_client is null then raise exception 'Request ID required';end if;select * into w from public.cb_experience_song_import_writes where user_id=auth.uid() and client=p_client;
 if found then if w.payload is distinct from payload then raise exception 'Retry the original reviewed song';end if;return w.response;end if;
 if p_confirm is distinct from true then raise exception 'Confirm sharing the reviewed song';end if;
 if e.revision is distinct from p_event_revision or src->>'hash' is distinct from p_source_hash then raise exception 'The song or celebration changed. Refresh your preview.' using errcode='PT409';end if;
 select * into l from public.cb_experience_song_imports where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=p_ref and event_id=e.id;
 if found then result=jsonb_build_object('track',l.track_id,'event',e.id,'already_shared',true);
 else
  select * into p from public.cb_experience_playlists where event_id=e.id for update;
  if coalesce(p.revision,0) is distinct from p_playlist_revision then raise exception 'The team playlist changed. Refresh your preview before adding this song.' using errcode='PT409';end if;
  if jsonb_typeof(p_data) is distinct from 'object' or p_data ? 'id' then raise exception 'Review the displayed song fields';end if;
  track=gen_random_uuid();written=public.cb_save_experience_playlist(e.id,e.revision,coalesce(p.revision,0),gen_random_uuid(),coalesce(p.tracks,'[]')||jsonb_build_array(p_data||jsonb_build_object('id',track)));
  insert into public.cb_experience_song_imports(user_id,scope,project_ref,record_ref,event_id,track_id,source_hash) values(auth.uid(),p_scope,p_project,p_ref,e.id,track,src->>'hash');
  result=jsonb_build_object('track',track,'event',e.id,'already_shared',false,'playlist_revision',written->'revision');
 end if;
 insert into public.cb_experience_song_import_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_experience_song_source(text,text,text),public.cb_experience_song_preview(text,text,text),public.cb_share_experience_song(text,text,text,uuid,bigint,bigint,text,uuid,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.cb_experience_song_preview(text,text,text),public.cb_share_experience_song(text,text,text,uuid,bigint,bigint,text,uuid,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';commit;
