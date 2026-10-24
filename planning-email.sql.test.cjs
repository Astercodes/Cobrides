const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('planning email opt-in queue and safe delivery',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');
 await db.exec("create schema vault;create table vault.decrypted_secrets(name text,decrypted_secret text);create schema net;create table net._http_response(id bigint,status_code int,content text,timed_out boolean,error_msg text);create table net.test_requests(id bigint generated always as identity,body jsonb,headers jsonb);create function net.http_post(url text,body jsonb default '{}',params jsonb default '{}',headers jsonb default '{}',timeout_milliseconds int default 1000) returns bigint language plpgsql as $$declare n bigint;begin if url<>'https://api.resend.com/emails' then raise exception 'Wrong endpoint';end if;insert into net.test_requests(body,headers) values(body,headers) returning id into n;return n;end;$$;");
 const mailSQL=fs.readFileSync('supabase/planning-email.sql','utf8');await db.exec(mailSQL);await db.exec(mailSQL);for(const file of ['collaboration-access','shared-decisions','decision-notifications'])await db.exec(fs.readFileSync('supabase/'+file+'.sql','utf8'));let task,job,request;
 const zone=(await one("select case when extract(hour from now() at time zone 'UTC')>=9 then 'UTC' else 'Etc/GMT-12' end as zone")).zone;
 await t.test('disabled by default and worker credentials cannot be read by ordinary accounts',async()=>{
  await as(2);assert.equal((await one('select public.cb_planning_email_status() as s')).s.enabled,false);
  await assert.rejects(q("select public.cb_set_planning_delivery(array['assignments'],$1,true)",[zone]),/unavailable/);
  await assert.rejects(q('select * from public.cb_planning_email_jobs'),/permission denied/);
  await assert.rejects(q('select public.cb_process_planning_email()'),/permission denied/);
  await assert.rejects(q("select decrypted_secret from vault.decrypted_secrets"),/permission denied/);
 });
 await db.exec('reset role');await q("insert into vault.decrypted_secrets values('cobridey_resend_api_key','re_test_key_private')");
 await t.test('only opted-in recipients receive one frozen summary with no private record titles',async()=>{
  await as(2);await q("select public.cb_set_planning_delivery(array['assignments','approvals','deadlines','schedule'],$1,true)",[zone]);
  await as(0);task=await one("select * from public.cb_save_board_task($1,'mail:task',0,'Private floral details','vendor@example.com',null,'task','','{}',false,'')",[project.id]);
  await db.exec('reset role');assert.equal((await one('select public.cb_process_planning_email() as s')).s.status,'submitted');
  job=await one('select * from public.cb_planning_email_jobs');request=await one('select * from net.test_requests');
  assert.equal(job.user_id,ids[2]);assert.equal(job.state,'inflight');assert.equal(request.body.to[0],'vendor@example.com');assert(!request.body.html.includes('Private floral details'));assert(request.body.html.includes('Manage email preferences'));assert.equal(request.headers['Idempotency-Key'],'cobridey-planning/'+job.id);
  await q("insert into net._http_response values($1,200,$2,false,null)",[job.request_id,JSON.stringify({id:'resend-test-id'})]);
  await q('select public.cb_process_planning_email()');assert.equal((await one('select state from public.cb_planning_email_jobs')).state,'accepted');
  await q('select public.cb_process_planning_email()');assert.equal((await q('select * from net.test_requests')).rows.length,1);
 });
 await t.test('retries preserve payload and idempotency and stop before the provider deduplication window expires',async()=>{
  await db.exec('reset role');await q("update public.cb_planning_email_jobs set state='queued',next_attempt_at=now(),last_attempt_at=now()-interval '2 minutes'");
  await q('select public.cb_process_planning_email()');const retry=await one('select * from net.test_requests order by id desc limit 1');assert.deepEqual(retry.body,request.body);assert.equal(retry.headers['Idempotency-Key'],request.headers['Idempotency-Key']);
  await q("update public.cb_planning_email_jobs set state='queued',first_attempt_at=now()-interval '21 hours',last_attempt_at=now()-interval '2 minutes'");
  await q('select public.cb_process_planning_email()');assert.equal((await one('select state from public.cb_planning_email_jobs')).state,'uncertain');assert.equal((await q('select * from net.test_requests')).rows.length,2);
 });
 await t.test('application allowance prevents new submissions before provider quota is consumed',async()=>{
  await db.exec('reset role');await q("update public.cb_planning_email_jobs set state='queued',first_attempt_at=null,last_attempt_at=null,attempts=0,next_attempt_at=now(),payload=null");
  await q("insert into public.cb_planning_email_jobs(user_id,local_day,state,notice_through,first_attempt_at) values($1,current_date,'accepted',now(),now())",[ids[1]]);
  await q('update public.cb_planning_email_settings set daily_limit=1');
  assert.equal((await one('select public.cb_process_planning_email() as s')).s.status,'application_allowance_reached');
  assert.equal((await q('select * from net.test_requests')).rows.length,2);await q('update public.cb_planning_email_settings set daily_limit=50,monthly_limit=1');
  assert.equal((await one('select public.cb_process_planning_email() as s')).s.status,'application_allowance_reached');
  await q('update public.cb_planning_email_settings set monthly_limit=1500');
 });
 await t.test('provider throttling backs off instead of flooding Resend',async()=>{
  await q('select public.cb_process_planning_email()');job=await one("select * from public.cb_planning_email_jobs where user_id=$1",[ids[2]]);
  await q("insert into net._http_response values($1,429,'{}',false,null)",[job.request_id]);await q('select public.cb_process_planning_email()');
  assert.equal((await one("select state from public.cb_planning_email_jobs where user_id=$1",[ids[2]])).state,'queued');assert((await one('select pause_until from public.cb_planning_email_settings')).pause_until);
 });
 await t.test('local morning scheduling is respected even when a time zone changes',async()=>{
  await db.exec('reset role');const early=(await one("select name from pg_timezone_names where extract(hour from now() at time zone name)<9 limit 1")).name;
  const day=(await one("select (now() at time zone $1)::date::text as day",[early])).day;
  await q('update public.cb_planning_email_settings set pause_until=null');
  await q("update public.cb_planning_preferences set time_zone=$1 where user_id=$2",[early,ids[2]]);
  await q("update public.cb_planning_email_jobs set state='queued',next_attempt_at=now(),last_attempt_at=null,local_day=$1 where user_id=$2",[day,ids[2]]);
  const before=(await q('select * from net.test_requests')).rows.length;await q('select public.cb_process_planning_email()');assert.equal((await q('select * from net.test_requests')).rows.length,before);
  await q('update public.cb_planning_preferences set time_zone=$1 where user_id=$2',[zone,ids[2]]);
  await q("update public.cb_planning_email_jobs set local_day=(now() at time zone $1)::date where user_id=$2",[zone,ids[2]]);
 });
 await t.test('revoked project access cancels a queued summary before any external send',async()=>{
  await as(0);await q('select public.cb_remove_member($1,$2)',[project.id,ids[2]]);
  await db.exec('reset role');const before=(await q('select * from net.test_requests')).rows.length;await q('select public.cb_process_planning_email()');
  assert.equal((await q('select * from net.test_requests')).rows.length,before);
  assert.equal((await one('select state from public.cb_planning_email_jobs where user_id=$1',[ids[2]])).state,'cancelled');
 });
 await t.test('opt-out immediately cancels unsent mail and does not change another user preference',async()=>{
  await db.exec('reset role');await q("update public.cb_planning_email_jobs set state='queued' where user_id='33333333-3333-4333-8333-333333333333'");
  await as(2);await q("select public.cb_set_planning_delivery(array['assignments'],$1,false)",[zone]);assert.equal((await one('select public.cb_planning_email_status() as s')).s.enabled,false);
  await db.exec('reset role');assert.equal((await one('select state from public.cb_planning_email_jobs where user_id=$1',[ids[2]])).state,'cancelled');
  await as(1);assert.equal((await one('select public.cb_planning_email_status() as s')).s.enabled,false);
 });
 }finally{await db.close();}
});
