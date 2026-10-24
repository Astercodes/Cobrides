const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('planning email delivery event safety',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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
 const mailSQL=fs.readFileSync('supabase/planning-email.sql','utf8');await db.exec(mailSQL);await db.exec(mailSQL);let task,job,request;
 const zone=(await one("select case when extract(hour from now() at time zone 'UTC')>=9 then 'UTC' else 'Etc/GMT-12' end as zone")).zone;

 const deliverySQL=fs.readFileSync('supabase/planning-delivery.sql','utf8');await db.exec(deliverySQL);await db.exec(deliverySQL);
 const secret='whsec_private_test_token_123456789';await q("insert into vault.decrypted_secrets values('cobridey_resend_webhook_secret',$1)",[secret]);
 await q("insert into vault.decrypted_secrets values('cobridey_resend_api_key','re_test_key_private')");
 await as(2);await q("select public.cb_set_planning_delivery(array['assignments'],$1,true)",[zone]);
 await db.exec('reset role');job=(await q("insert into public.cb_planning_email_jobs(user_id,local_day,state,notice_through,payload) values($1,current_date,'accepted',now(),$2) returning *",[ids[2],{to:['vendor@example.com']}])).rows[0];
 const record=async(id,email,kind,time='2026-10-23T12:00:00Z',token=secret)=>q("select public.cb_record_planning_delivery($1,$2,$3,$4,$5)",[token,id,email,kind,time]);
 await t.test('forged tokens cannot record events or read private delivery jobs',async()=>{
  await as(3);await assert.rejects(record('msg_bad','provider-1','email.bounced',undefined,'wrong'),/access denied/);
  await assert.rejects(q('select * from public.cb_planning_delivery_events'),/permission denied/);
 });
 await t.test('out-of-order provider callbacks are retained until the sending job is linked',async()=>{
  await record('msg_delivery','provider-1','email.delivered');
  await db.exec('reset role');assert.equal((await one("select processed_at from public.cb_planning_delivery_events where event_id='msg_delivery'")).processed_at,null);
  await q("update public.cb_planning_email_jobs set provider_id='provider-1' where id=$1",[job.id]);
  assert.equal((await one('select delivery_state from public.cb_planning_email_jobs where id=$1',[job.id])).delivery_state,'email.delivered');
  await record('msg_delivery','provider-1','email.delivered');assert.equal((await q('select * from public.cb_planning_delivery_events')).rows.length,1);
 });
 await t.test('hard bounces pause the affected address and cancel queued work',async()=>{
  await q("insert into public.cb_planning_email_jobs(user_id,local_day,state,notice_through) values($1,current_date+1,'queued',now())",[ids[2]]);
  await record('msg_bounce','provider-1','email.bounced','2026-10-23T12:01:00Z');
  assert.equal((await one('select email_opt_in from public.cb_planning_preferences where user_id=$1',[ids[2]])).email_opt_in,false);
  assert.equal((await one("select state from public.cb_planning_email_jobs where user_id=$1 and state='cancelled'",[ids[2]])).state,'cancelled');
  await as(2);assert((await one('select public.cb_planning_email_status() as s')).s.suppressed);
  await assert.rejects(q("select public.cb_set_planning_delivery(array['assignments'],$1,true)",[zone]),/paused/);
 });
 await t.test('late delivered events cannot erase a bounce or another account suppression',async()=>{
  await record('msg_old_delivered','provider-1','email.delivered','2026-10-23T11:59:00Z');await db.exec('reset role');
  assert.equal((await one('select delivery_state from public.cb_planning_email_jobs where id=$1',[job.id])).delivery_state,'email.bounced');
  await as(1);assert.equal((await one('select public.cb_planning_email_status() as s')).s.suppressed,false);
 });
 await t.test('a newly verified address can opt in without clearing the old address block',async()=>{
  await db.exec('reset role');await q("update auth.users set email='new@example.com' where id=$1",[ids[2]]);
  await as(2);await q("select public.cb_set_planning_delivery(array['assignments'],$1,true)",[zone]);assert.equal((await one('select public.cb_planning_email_status() as s')).s.suppressed,false);
 });
 }finally{await db.close();}
});

