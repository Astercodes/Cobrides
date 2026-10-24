const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('shared conversations enforce participant privacy and persistent delivery',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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
 await as(0);project=await one("select * from public.cb_create_wedding_project('chat:wedding','Our wedding','{}',0,'USD')");
 for(const [i,role] of [[1,'planner'],[2,'friend']]){const invite=await one("insert into public.cb_invites(project_id,email,role,created_by) values($1,$2,$3,$4) returning token",[project.id,['bride','planner','vendor'][i]+'@example.com',role,ids[0]]);await as(i);await q('select public.cb_accept_invite($1)',[invite.token]);await as(0);}
 let thread,mid;
 await t.test('accepted participants only; ownership and planning roles do not bypass private chat',async()=>{
  await assert.rejects(q("select public.cb_create_chat($1,'Private',array[$2::uuid])",[project.id,ids[3]]),/accepted wedding teammates/);
  thread=(await one("select public.cb_create_chat($1,'Our celebration',array[$2::uuid]) id",[project.id,ids[2]])).id;
  await as(1);assert.deepEqual((await one('select public.cb_list_chats($1) result',[project.id])).result,[]);await assert.rejects(q('select public.cb_chat_history($1,null)',[thread]),/access denied/);
  const privateThread=(await one("select public.cb_create_chat($1,'Planner and friend',array[$2::uuid]) id",[project.id,ids[2]])).id;await as(0);await assert.rejects(q('select public.cb_chat_history($1,null)',[privateThread]),/access denied/);
  await as(3);await assert.rejects(q('select public.cb_chat_people($1)',[project.id]),/access denied/);
 });
 await t.test('messages cannot spoof authors, retries do not duplicate, and receipts are account-owned',async()=>{
  await as(0);const client='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';mid=(await one("select public.cb_send_chat_message($1,$2,'Our tasting is confirmed','[]') id",[thread,client])).id;
  assert.equal((await one("select public.cb_send_chat_message($1,$2,'Our tasting is confirmed','[]') id",[thread,client])).id,mid);
  await assert.rejects(q("select public.cb_send_chat_message($1,$2,'Changed retry','[]')",[thread,client]),/changed during retry/);
  await assert.rejects(q('select * from public.cb_chat_messages'),/permission denied/);await assert.rejects(q("insert into public.cb_chat_messages(thread_id,author_id,client_id,body) values($1,$2,$3,'Forged')",[thread,ids[2],client]),/permission denied/);
  await as(2);assert.equal((await one('select public.cb_list_chats($1) result',[project.id])).result.find(t=>t.id===thread).unread,1);
  await q('select public.cb_mark_chat_read($1,999999999)',[thread]);await as(0);const history=(await one('select public.cb_chat_history($1,null) result',[thread])).result;assert.equal(history.messages.length,1);assert.equal(history.messages[0].read_by,1);
  await q("select public.cb_send_chat_message($1,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Next appointment','[]')",[thread]);await as(2);assert.equal((await one('select public.cb_list_chats($1) result',[project.id])).result.find(t=>t.id===thread).unread,1);
 });
 await t.test('files require uploader ownership and are readable only to permitted participants',async()=>{
  await db.exec('reset role');await q("insert into storage.objects(bucket_id,name) values('cb-documents',$1),('cb-documents',$2)",[ids[0]+'/own.pdf',ids[3]+'/private.pdf']);await as(0);
  await assert.rejects(q("select public.cb_send_chat_message($1,gen_random_uuid(),'Wrong file',$2)",[thread,[{bucket:'cb-documents',path:ids[3]+'/private.pdf',name:'Private.pdf'}]]),/own file/);
  await q("select public.cb_send_chat_message($1,gen_random_uuid(),'Our agreement',$2)",[thread,[{bucket:'cb-documents',path:ids[0]+'/own.pdf',name:'Agreement.pdf'}]]);
  let history=(await one('select public.cb_chat_history($1,null) result',[thread])).result,file=history.messages.at(-1).files[0];await as(2);assert.equal((await one('select public.cb_chat_file($1) result',[file.id])).result.path,ids[0]+'/own.pdf');assert.equal((await q('select * from storage.objects')).rows.length,1);
  await as(1);await assert.rejects(q('select public.cb_chat_file($1)',[file.id]),/access denied/);assert.equal((await q('select * from storage.objects')).rows.length,0);await as(0);assert.equal((await one("select public.cb_file_referenced('cb-documents',$1) result",[ids[0]+'/own.pdf'])).result,true);
 });
 await t.test('archive blocks sends but preserves history; removal immediately blocks history files and receipts',async()=>{
  await db.exec('reset role');await q('update public.cb_projects set archived_at=now() where id=$1',[project.id]);await as(0);assert((await one('select public.cb_chat_history($1,null) result',[thread])).result.messages.length>0);await assert.rejects(q("select public.cb_send_chat_message($1,gen_random_uuid(),'Archived','[]')",[thread]),/access denied/);await db.exec('reset role');await q('update public.cb_projects set archived_at=null where id=$1',[project.id]);await as(0);await q('select public.cb_remove_member($1,$2)',[project.id,ids[2]]);await as(2);await assert.rejects(q('select public.cb_chat_history($1,null)',[thread]),/access denied/);await assert.rejects(q('select public.cb_mark_chat_read($1,1)',[thread]),/access denied/);assert.equal((await q('select * from storage.objects')).rows.length,0);
 });
 }finally{await db.close();}
});
