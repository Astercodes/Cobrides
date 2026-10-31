const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('shared song order is permission controlled, revisioned and retry safe',{skip:!process.env.CB_PGLITE_PATH},async()=>{
 const {PGlite}=require(process.env.CB_PGLITE_PATH),db=new PGlite(),ids=['11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444'];let project,event;
 const q=(sql,args)=>db.query(sql,args),one=async(sql,args)=>(await q(sql,args)).rows[0];
 const as=async i=>{await db.exec('reset role');await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:ids[i],email:['bride','planner','vendor','other'][i]+'@example.com'})]);await db.exec('set role authenticated');};
 try{await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 create function auth.uid() returns uuid language sql stable as $$select (auth.jwt()->>'sub')::uuid$$;grant usage on schema auth,public to authenticated;`);
 for(let i=0;i<4;i++)await q('insert into auth.users values($1,$2,now())',[ids[i],['bride','planner','vendor','other'][i]+'@example.com']);
 await db.exec(fs.readFileSync('supabase/collaboration.sql','utf8'));await db.exec(fs.readFileSync('supabase/accounts.sql','utf8'));
 await q("insert into public.cb_profiles(user_id,full_name,account_type,business_name) values($1,'Planner','planner','Planner Studio')",[ids[1]]);
 const sql=fs.readFileSync('supabase/wedding-projects.sql','utf8');await db.exec(sql);await db.exec(sql);const planningSQL=fs.readFileSync('supabase/shared-planning.sql','utf8');await db.exec(planningSQL);await db.exec(planningSQL);const rolesSQL=fs.readFileSync('supabase/team-invitation-roles.sql','utf8');await db.exec(rolesSQL);await db.exec(rolesSQL);
 await db.exec(`create schema storage;create table storage.objects(bucket_id text,name text,metadata jsonb);alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select on storage.objects to authenticated;create table public.cb_file_reservations(bucket text,path text,deleting boolean default false);create function public.cb_file_referenced(text,text) returns boolean language sql as $$select false$$;`);
 const boardSQL=fs.readFileSync('supabase/task-board.sql','utf8');await db.exec(boardSQL);await db.exec(boardSQL);const celebrationSQL=fs.readFileSync('supabase/celebration-workspace.sql','utf8');await db.exec(celebrationSQL);await db.exec(celebrationSQL);const timelineSQL=fs.readFileSync('supabase/shared-timeline.sql','utf8');await db.exec(timelineSQL);await db.exec(timelineSQL);
 await as(0);


 await db.exec('reset role');const chatSQL=fs.readFileSync('supabase/communication-hub.sql','utf8');await db.exec(chatSQL);await db.exec(chatSQL);
 await db.exec(fs.readFileSync('supabase/collaboration-access.sql','utf8'));
 await as(0);project=await one("select * from public.cb_create_wedding_project('chat:wedding','Our wedding','{}',0,'USD')");
 for(const [i,role] of [[1,'planner'],[2,'friend']]){const invite=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,$2,$3,$4) returning token",[project.id,['bride','planner','vendor'][i]+'@example.com',role,ids[0]]);await as(i);await q('select public.cb_accept_invite($1)',[invite.token]);await as(0);}


await db.exec('reset role');await db.exec(fs.readFileSync('supabase/shared-experience.sql','utf8'));const musicSQL=fs.readFileSync('supabase/experience-playlist.sql','utf8');await db.exec(musicSQL);await db.exec(musicSQL);await as(0);event=await one("select * from public.cb_save_project_event($1,'reception',0,'Reception','{}','restricted')",[project.id]);
const read=()=>one('select public.cb_experience_playlist($1) v',[event.id]).then(r=>r.v),song={id:crypto.randomUUID(),title:'Perfect',artist:'Ed Sheeran',moment:'First dance',time:'18:30',url:'https://example.com/song',instructions:'Fade after the chorus',list:'Play'},client=crypto.randomUUID();
const save=(tracks=[song],rev=0,key=crypto.randomUUID(),er=event.revision)=>one('select public.cb_save_experience_playlist($1,$2,$3,$4,$5) v',[event.id,er,rev,key,tracks]).then(r=>r.v);
assert.equal((await read()).revision,0);const first=await save([song],0,client);assert.equal(first.revision,1);assert.deepEqual(await save([song],0,client),first);await assert.rejects(save([{...song,title:'Changed'}],0,client),/original playlist/);await assert.rejects(save([song],0),/Another coordinator/);await assert.rejects(save([song],1,crypto.randomUUID(),99),/celebration changed/);
for(const bad of [[song,song],[{...song,time:'25:00'}],[{...song,url:'javascript:alert(1)'}],[{...song,amount:'100'}],[{...song,title:''}],[{...song,list:'Ready'}]])await assert.rejects(save(bad,1));
const second={...song,id:crypto.randomUUID(),title:'Do not play this',list:'Do not play'};await save([second,song],1);assert.deepEqual((await read()).tracks,[second,song]);await assert.rejects(q('select * from public.cb_experience_playlists'),/permission denied/);
await as(1);await save([song,second],2);await as(2);await assert.rejects(read(),/Celebration access/);await assert.rejects(save([],3),/planning access/);await as(0);await q('select public.cb_set_event_member($1,$2,true)',[event.id,ids[2]]);await as(2);assert.equal((await read()).can_edit,false);await assert.rejects(save([],3),/planning access/);await as(3);await assert.rejects(read(),/Celebration access/);
await db.exec('reset role');await q('update public.cb_projects set archived_at=now() where id=$1',[project.id]);await as(0);assert.equal((await read()).can_edit,false);await assert.rejects(save([],3),/planning access/);await db.exec('set role anon');await assert.rejects(read(),/permission denied/);
}finally{await db.close();}});
