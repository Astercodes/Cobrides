const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('shared planning notification permissions and reminders',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 const migration=fs.readFileSync('supabase/planning-notifications.sql','utf8');await db.exec('reset role');await db.exec(migration);await db.exec(migration);await as(0);
 project=await one("select * from public.cb_create_wedding_project('notice:project','Our wedding','{}',0,'USD')");
 for(const [i,role] of [[1,'planner'],[2,'friend']]){const invite=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,$2,$3,$4) returning token",[project.id,['bride','planner','vendor'][i]+'@example.com',role,ids[0]]);await as(i);await q('select public.cb_accept_invite($1)',[invite.token]);await as(0);}
 let task;const inbox=async()=> (await one('select public.cb_planning_inbox() as data')).data;
 await t.test('assignment and approval go only to permitted recipients, not actor or outsider',async()=>{
  task=await one("select * from public.cb_save_board_task($1,'notice:task',0,'Confirm flowers','vendor@example.com',current_date+2,'task','','{}',true,'planner@example.com')",[project.id]);
  await as(2);let data=await inbox();assert(data.items.some(n=>n.kind==='assigned'));assert(!data.items.some(n=>n.category==='approvals'));
  await as(1);data=await inbox();assert(data.items.some(n=>n.kind==='approval_requested'));
  await as(3);assert.equal((await inbox()).items.length,0);await as(0);assert(!(await inbox()).items.some(n=>n.kind==='assigned'));
 });
 await t.test('reminders are generated once per deadline and state, with read state scoped to the recipient',async()=>{
  await as(2);const first=await inbox(),second=await inbox();assert.equal(first.items.filter(n=>n.category==='deadlines').length,1);assert.equal(first.items.length,second.items.length);
  const notice=first.items[0];await q('select public.cb_read_planning_notifications($1,false)',[notice.id]);assert((await inbox()).items.find(n=>n.id===notice.id).read_at);
  await as(3);await q('select public.cb_read_planning_notifications($1,false)',[notice.id]);assert.equal((await q('select * from public.cb_planning_notifications')).rows.length,0);
  await assert.rejects(q("select public.cb_generate_planning_reminders(null)"),/permission denied/);
  await assert.rejects(q("insert into public.cb_planning_notifications(user_id,project_id,category,kind,source_kind,source_id,title,body,dedupe_key) values($1,$2,'schedule','forged','project',$2,'Fake','Fake','fake')",[ids[3],project.id]),/permission denied/);
 });
 await t.test('preferences disable categories and time zones are validated',async()=>{
  await as(2);await q("select public.cb_set_planning_preferences(array['assignments'],'Africa/Lagos')");assert(!(await inbox()).items.some(n=>n.category==='deadlines'));
  await assert.rejects(q("select public.cb_set_planning_preferences(array['made-up'],'UTC')"),/valid notification/);
  await assert.rejects(q("select public.cb_set_planning_preferences(array['assignments'],'Nope/Zone')"),/valid time zone/);
  await q("select public.cb_set_planning_preferences(array['assignments','approvals','deadlines','schedule'],'UTC')");
 });
 await t.test('approved requests disappear and assignee receives the approval result',async()=>{
  await as(1);task=await one("select * from public.cb_task_step($1,$2,'',true,true)",[task.id,task.revision]);assert(!(await inbox()).items.some(n=>n.kind==='approval_requested'));
  await as(2);assert((await inbox()).items.some(n=>n.kind==='approved'));
 });
 await t.test('celebration reminders use source permissions and do not repeat',async()=>{
  await as(0);const day=(await one("select (current_date+1)::text as day")).day;
  const upcoming=await one("select * from public.cb_save_project_event($1,'notice:upcoming',0,'Reception',$2,'restricted')",[project.id,{date:day}]);
  await as(2);assert(!(await inbox()).items.some(n=>n.source_id===upcoming.id));
  await as(1);assert.equal((await inbox()).items.filter(n=>n.source_id===upcoming.id).length,1);assert.equal((await inbox()).items.filter(n=>n.source_id===upcoming.id).length,1);
 });
 await t.test('restricted celebration changes cannot leak to ordinary members',async()=>{
  await as(0);event=await one("select * from public.cb_save_project_event($1,'notice:event',0,'Secret family lunch',$2,'restricted')",[project.id,{date:'2028-01-01'}]);
  event=await one("select * from public.cb_save_project_event($1,'notice:event',$2,'Secret family lunch',$3,'restricted')",[project.id,event.revision,{date:'2028-01-02'}]);
  await as(2);assert(!(await inbox()).items.some(n=>n.source_id===event.id));
  await as(1);assert((await inbox()).items.some(n=>n.source_id===event.id));
 });
 await t.test('reassignment immediately removes old task notifications; date changes invalidate old reminders',async()=>{
  await as(0);task=await one("select * from public.cb_save_shared_task($1,'notice:task',$2,'Confirm flowers','planner@example.com',current_date+10,'task','')",[project.id,task.revision]);
  await as(2);assert(!(await inbox()).items.some(n=>n.source_id===task.id));
  await as(1);assert(!(await inbox()).items.some(n=>n.source_id===task.id&&n.category==='deadlines'));assert((await inbox()).items.some(n=>n.kind==='date_changed'));
 });
 await t.test('failed task transactions do not leave assignment notifications behind',async()=>{
  await as(2);const before=(await inbox()).items.length;await as(0);
  await assert.rejects(q("select * from public.cb_save_board_task($1,'notice:rollback',0,'Should not appear','vendor@example.com',null,'task','',$2,false,'')",[project.id,{priority:'Invalid'}]),/priority/);
  await as(2);assert.equal((await inbox()).items.length,before);await as(0);
 });
 await t.test('membership revocation and archival remove inbox access immediately',async()=>{
  await as(0);await q('select public.cb_remove_member($1,$2)',[project.id,ids[1]]);await as(1);assert.equal((await inbox()).items.length,0);
  await as(0);project=await one('select * from public.cb_projects where id=$1',[project.id]);await q('select public.cb_set_project_archived($1,$2,true)',[project.id,project.revision]);assert.equal((await inbox()).items.length,0);
 });
 }finally{await db.close();}
});
