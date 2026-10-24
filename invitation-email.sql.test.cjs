const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('direct invitation email permissions and delivery',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');const inviteSQL=fs.readFileSync('supabase/invitation-email.sql','utf8');await db.exec(inviteSQL);await db.exec(inviteSQL);
 let invite;
 await t.test('only verified wedding managers can request email; private jobs stay private',async()=>{
  await as(0);invite=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,'other@example.com','friend',$2) returning *",[project.id,ids[0]]);
  await as(3);await assert.rejects(q('select public.cb_send_invitation_email($1)',[invite.id]),/access denied/);await assert.rejects(q('select public.cb_invitation_email_status($1)',[invite.id]),/access denied/);await assert.rejects(q('select * from public.cb_invitation_email_jobs'),/permission denied/);
  await as(0);assert.equal((await one('select public.cb_send_invitation_email($1) result',[invite.id])).result.state,'queued');
  await q('select public.cb_send_invitation_email($1)',[invite.id]);await db.exec('reset role');assert.equal((await one('select count(*)::int n from public.cb_invitation_email_jobs')).n,1);
 });
 await t.test('sender uses a frozen branded payload and delivery callbacks provide status',async()=>{
  await db.exec('reset role');await q('select public.cb_process_invitation_email()');let mail=await one('select * from net.test_requests order by id desc limit 1');assert.equal(mail.body.to[0],'other@example.com');assert(mail.body.html.includes('Your Bridal Journey Companion'));assert(mail.body.html.includes('https://www.cobridey.com/collaborate.html#invite='+invite.token));
  await q("insert into net._http_response values($1,200,'{\"id\":\"invite-provider\"}',false,null)",[mail.id]);await q('select public.cb_process_invitation_email()');await record('msg_invite_delivered','invite-provider','email.delivered');await as(0);let status=(await one('select public.cb_invitation_email_status($1) result',[invite.id])).result;assert.equal(status.state,'accepted');assert.equal(status.delivery,'email.delivered');
 });
 await t.test('hard bounces prevent sending more invitations to the rejected address',async()=>{
  await record('msg_invite_bounce','invite-provider','email.bounced');await as(0);let next=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,'other@example.com','friend',$2) returning *",[project.id,ids[0]]);await assert.rejects(q('select public.cb_send_invitation_email($1)',[next.id]),/unavailable for this address/);
 });
 await t.test('revocation cancels queued delivery without submitting to the provider',async()=>{
  await as(0);let revoked=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,'revoked@example.com','friend',$2) returning *",[project.id,ids[0]]);await q('select public.cb_send_invitation_email($1)',[revoked.id]);await q('select public.cb_revoke_invite($1)',[revoked.id]);await db.exec('reset role');let before=(await one('select count(*)::int n from net.test_requests')).n;await q('select public.cb_process_invitation_email()');assert.equal((await one('select state from public.cb_invitation_email_jobs where invite_id=$1',[revoked.id])).state,'cancelled');assert.equal((await one('select count(*)::int n from net.test_requests')).n,before);
 });
 await t.test('expired and archived weddings reject sending; unverified accounts cannot send',async()=>{
  await as(0);let expired=await one("insert into public.cb_invites(project_id,email,role,created_by,expires_at) values($1,'expired@example.com','friend',$2,now()-interval '1 minute') returning *",[project.id,ids[0]]);await assert.rejects(q('select public.cb_send_invitation_email($1)',[expired.id]),/no longer pending/);
  let pending=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,'valid@example.com','friend',$2) returning *",[project.id,ids[0]]);await db.exec('reset role');await q('update auth.users set email_confirmed_at=null where id=$1',[ids[0]]);await as(0);await assert.rejects(q('select public.cb_send_invitation_email($1)',[pending.id]),/Verify your email/);await db.exec('reset role');await q('update auth.users set email_confirmed_at=now() where id=$1',[ids[0]]);await q('update public.cb_projects set archived_at=now() where id=$1',[project.id]);await as(0);await assert.rejects(q('select public.cb_send_invitation_email($1)',[pending.id]),/access denied/);await db.exec('reset role');await q('update public.cb_projects set archived_at=null where id=$1',[project.id]);
 });
 await t.test('temporary failure retries use exactly the same payload and idempotency key',async()=>{
  await as(0);let retry=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,'retry@example.com','friend',$2) returning *",[project.id,ids[0]]);await q('select public.cb_send_invitation_email($1)',[retry.id]);await db.exec('reset role');await db.exec("update public.cb_invitation_email_jobs set last_attempt_at=now()-interval '1 minute'");await q('select public.cb_process_invitation_email()');let first=await one('select * from net.test_requests order by id desc limit 1');await q("insert into net._http_response values($1,500,'{}',false,null)",[first.id]);await q('select public.cb_process_invitation_email()');await db.exec("update public.cb_invitation_email_jobs set next_attempt_at=now()-interval '1 minute',last_attempt_at=now()-interval '1 minute'");await q('select public.cb_process_invitation_email()');let second=await one('select * from net.test_requests order by id desc limit 1');assert.notEqual(first.id,second.id);assert.deepEqual(first.body,second.body);assert.equal(first.headers['Idempotency-Key'],second.headers['Idempotency-Key']);
 });
 }finally{await db.close();}
});
