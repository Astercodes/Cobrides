-- Shared, ordered music planning. Does not stream music or execute production cues.
begin;
create table if not exists public.cb_experience_playlists(event_id uuid primary key references public.cb_project_events on delete cascade,tracks jsonb not null default '[]',revision bigint not null default 1,updated_by uuid not null references auth.users,updated_at timestamptz not null default now());
create table if not exists public.cb_experience_playlist_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_experience_playlist_history(event_id uuid not null references public.cb_project_events on delete cascade,revision bigint not null,tracks jsonb not null,actor_id uuid not null references auth.users,at timestamptz not null default now(),primary key(event_id,revision));
alter table public.cb_experience_playlists enable row level security;
alter table public.cb_experience_playlist_writes enable row level security;
alter table public.cb_experience_playlist_history enable row level security;
revoke all on public.cb_experience_playlists,public.cb_experience_playlist_writes,public.cb_experience_playlist_history from public,anon,authenticated;
create or replace function public.cb_experience_playlist(p_event uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e public.cb_project_events;p public.cb_experience_playlists;
begin
 select * into e from public.cb_project_events where id=p_event;
 if e.id is null or not coalesce(public.cb_experience_member(e.id,auth.uid()),false) then raise exception 'Celebration access required' using errcode='42501';end if;
 select * into p from public.cb_experience_playlists where event_id=e.id;
 return jsonb_build_object('event',e.id,'event_revision',e.revision,'title',e.title,'can_edit',public.cb_project_access(e.project_id,'write'),'revision',coalesce(p.revision,0),'tracks',coalesce(p.tracks,'[]'),'updated_at',p.updated_at);
end;$$;
create or replace function public.cb_save_experience_playlist(p_event uuid,p_event_revision bigint,p_revision bigint,p_client uuid,p_tracks jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.cb_project_events;p public.cb_experience_playlists;w public.cb_experience_playlist_writes;payload jsonb;result jsonb;t jsonb;k text;seen text[]='{}';
begin
 select * into e from public.cb_project_events where id=p_event;
 perform 1 from public.cb_projects where id=e.project_id for update;
 select * into e from public.cb_project_events where id=p_event for update;
 if e.id is null or not coalesce(public.cb_project_access(e.project_id,'write') and public.cb_experience_member(e.id,auth.uid()),false) then raise exception 'Celebration planning access required' using errcode='42501';end if;
 if p_client is null then raise exception 'Request ID required';end if;
 payload=jsonb_build_object('event',p_event,'event_revision',p_event_revision,'revision',p_revision,'tracks',p_tracks);
 select * into w from public.cb_experience_playlist_writes where user_id=auth.uid() and client=p_client;
 if found then if w.payload is distinct from payload then raise exception 'Retry the original playlist request';end if;return w.response;end if;
 if e.revision is distinct from p_event_revision then raise exception 'The celebration changed. Refresh before saving.' using errcode='PT409';end if;
 select * into p from public.cb_experience_playlists where event_id=e.id for update;
 if coalesce(p.revision,0) is distinct from p_revision then raise exception 'Another coordinator changed the playlist. Your edits remain here; copy them before refreshing.' using errcode='PT409';end if;
 if jsonb_typeof(p_tracks) is distinct from 'array' then raise exception 'Choose a song list';end if;
 if jsonb_array_length(p_tracks)>300 then raise exception 'Use up to 300 songs per celebration';end if;
 for t in select value from jsonb_array_elements(p_tracks) loop
  if jsonb_typeof(t) is distinct from 'object' then raise exception 'Choose valid song details';end if;
  for k in select jsonb_object_keys(t) loop
   if k not in ('id','title','artist','moment','time','url','instructions','list') or jsonb_typeof(t->k) is distinct from 'string' then raise exception 'Unsupported song fields';end if;
  end loop;
  if coalesce(t->>'id','')!~'^[0-9a-fA-F-]{36}$' or (t->>'id')=any(seen) then raise exception 'Use unique song identifiers';end if;
  seen=array_append(seen,t->>'id');
  if length(trim(coalesce(t->>'title','')))=0 or length(t->>'title')>200 or length(coalesce(t->>'artist',''))>200 or length(coalesce(t->>'moment',''))>200 or length(coalesce(t->>'instructions',''))>2000 or length(coalesce(t->>'url',''))>2000 then raise exception 'Check song title and field lengths';end if;
  if coalesce(t->>'list','') not in ('Play','Do not play') then raise exception 'Choose Play or Do not play';end if;
  if coalesce(t->>'time','')<>'' and (t->>'time')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Choose a valid song time';end if;
  if coalesce(t->>'url','')<>'' and (t->>'url')!~'^https://[^[:space:]]+$' then raise exception 'Use an HTTPS music reference';end if;
 end loop;
 insert into public.cb_experience_playlists(event_id,tracks,updated_by) values(e.id,p_tracks,auth.uid()) on conflict(event_id) do update set tracks=excluded.tracks,revision=cb_experience_playlists.revision+1,updated_by=auth.uid(),updated_at=now() returning * into p;
 insert into public.cb_experience_playlist_history values(e.id,p.revision,p.tracks,auth.uid(),now());
 result=jsonb_build_object('revision',p.revision,'saved',true);
 insert into public.cb_experience_playlist_writes values(auth.uid(),p_client,payload,result);
 return result;
end;$$;
revoke all on function public.cb_experience_playlist(uuid),public.cb_save_experience_playlist(uuid,bigint,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_experience_playlist(uuid),public.cb_save_experience_playlist(uuid,bigint,bigint,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
