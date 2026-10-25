const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('reviewed payment schedules preserve history and update live reminders',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');const toolsSQL=fs.readFileSync('supabase/chat-tools.sql','utf8');await db.exec(toolsSQL);await db.exec(toolsSQL);await as(0);
 let thread,mid,foreign,poll,fileId;
 await db.exec('reset role');await db.exec(fs.readFileSync('supabase/planning-notifications.sql','utf8'));await db.exec('alter table public.cb_planning_preferences add column email_opt_in boolean not null default false');for(const f of ['shared-decisions','decision-notifications','chat-notifications'])await db.exec(fs.readFileSync('supabase/'+f+'.sql','utf8'));await db.exec(fs.readFileSync('supabase/chat-notifications.sql','utf8'));await as(0);
 await db.exec('reset role');const actionSql=fs.readFileSync('supabase/chat-actions.sql','utf8');await db.exec(actionSql);await db.exec(actionSql);await as(0);
 await db.exec('reset role');const migration=fs.readFileSync('supabase/chat-record-links.sql','utf8');await db.exec(migration);await db.exec(migration);await as(0);
 await db.exec('reset role');const migrationV=fs.readFileSync('supabase/shared-vendors.sql','utf8');await db.exec(migrationV);await db.exec(migrationV);await as(0);
 await db.exec('reset role');const sqlCommercial=fs.readFileSync('supabase/vendor-commercial.sql','utf8');await db.exec(sqlCommercial);await db.exec(sqlCommercial);await as(0);

 await db.exec('reset role');const ledgerSql=fs.readFileSync('supabase/shared-ledger.sql','utf8');await db.exec(ledgerSql);await db.exec(ledgerSql);const settlementSql=fs.readFileSync('supabase/expense-settlements.sql','utf8');await db.exec(settlementSql);await db.exec(settlementSql);await as(0);
 const vendor=(await one("select public.cb_save_shared_vendor($1,null,gen_random_uuid(),'ledger-vendor',0,'Petal Studio','{}',array[$2]::uuid[],false) data",[project.id,ids[2]])).data;
 const quote=(await one("select public.cb_save_vendor_quote($1,null,gen_random_uuid(),0,$2) data",[vendor.id,{title:'Flowers',currency:'NGN',amount:1000,tax:0,service:0,delivery:0,status:'Received'}])).data;
 const booking=(await one("select public.cb_save_vendor_booking($1,null,$2,1,gen_random_uuid(),0,$3,true) data",[vendor.id,quote.id,{title:'Reception flowers',scope:'Install',status:'Confirmed',milestones:[]}])).data;
 const ledger=async()=>(await one('select public.cb_shared_ledger($1) data',[project.id])).data;
 let expense;const client='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 const connect=async(c=client,rev=1)=>(await one('select public.cb_connect_booking_expense($1,$2,$3) data',[booking.id,rev,c])).data;
 const payment=async(amount,rev,kind='Payment',originalId='',c=require('node:crypto').randomUUID())=>(await one('select public.cb_record_shared_payment($1,$2,$3,$4) data',[expense.id,rev,c,{kind,amount,date:'2026-01-01',method:'Bank transfer',reference:'BANK-123',note:'Confirmed',originalId}])).data;
 const reconcile=async(rev,done,note='Checked against bank statement')=>(await one('select public.cb_reconcile_shared_expense($1,$2,gen_random_uuid(),$3,$4) data',[expense.id,rev,done,note])).data;

 await db.exec('reset role');const reminders=fs.readFileSync('supabase/expense-reminders.sql','utf8');await db.exec(reminders);await db.exec(reminders);await as(0);
 expense=await connect();await db.exec('reset role');await q("update public.cb_shared_expenses set schedule=$2 where id=$1",[expense.id,[{id:'deposit',title:'Deposit',amount:300,due:new Date().toISOString().slice(0,10)},{id:'balance',title:'Final',amount:700,due:'2099-01-01'}]]);await as(0);
 const inbox=async()=>(await one('select public.cb_planning_inbox() data')).data;

 await db.exec('reset role');const sqlSchedule=fs.readFileSync('supabase/expense-schedules.sql','utf8');await db.exec(sqlSchedule);await db.exec(sqlSchedule);await as(0);
 const today=new Date().toISOString().slice(0,10),soon=new Date(Date.now()+2*86400000).toISOString().slice(0,10),yesterday=new Date(Date.now()-86400000).toISOString().slice(0,10);
 const plan=[{id:'deposit',title:'Deposit already made',amount:300,due:today},{id:'balance',title:'Revised final payment',amount:500,due:soon}],scheduleClient=require('node:crypto').randomUUID();
 const review=async(rev,d=plan,c=scheduleClient,confirm=true,reason='Vendor confirmed revised dates')=>(await one('select public.cb_replace_expense_schedule($1,$2,$3,$4,$5,$6) data',[expense.id,rev,c,d,reason,confirm])).data;
 await payment(300,1);await q("select public.cb_adjust_expense_settlement($1,2,gen_random_uuid(),800,'Revised flowers package',true)",[expense.id]);
 await t.test('only authorized financial editors can replace schedules; full commitment and confirmation are required',async()=>{await as(1);await assert.rejects(review(3),/financial access/);await as(0);await assert.rejects(review(3,plan,scheduleClient,false),/Confirm/);await assert.rejects(review(3,[plan[1]]),/total the current commitment/);await assert.rejects(review(3,[plan[0],{...plan[1],id:'deposit'}]),/unique/);await assert.rejects(review(3,[plan[0],{...plan[1],due:'2026-02-31'}]),/date/);await assert.rejects(review(2),e=>e.code==='PT409');});
 await t.test('review revives valid reminders, covers paid deadlines and preserves snapshots',async()=>{const e=await review(3);assert.equal(e.schedule_total,800);assert.equal(e.agreed_total,1000);assert.equal((await review(3)).revision,4);await assert.rejects(review(3,[{...plan[0],title:'Changed'},plan[1]]),e=>e.code==='PT409');const rows=(await inbox()).items.filter(n=>n.source_kind==='expense');assert.equal(rows.length,1);assert.equal(rows[0].title,'Vendor payment coming up');assert.equal(rows[0].source_date,soon);const data=await ledger();assert.equal(data.expenses[0].schedule_history.length,1);assert.equal(data.expenses[0].schedule_history[0].previous_schedule[1].due,'2099-01-01');assert.equal(data.expenses[0].net_paid,300);});
 await t.test('rescheduled deadlines hide old notices and clearing a schedule stops reminders',async()=>{await review(4,[{...plan[0],due:new Date(Date.now()-2*86400000).toISOString().slice(0,10)},{...plan[1],due:yesterday}],require('node:crypto').randomUUID());const rows=(await inbox()).items.filter(n=>n.source_kind==='expense');assert.equal(rows.length,1);assert.equal(rows[0].title,'Vendor payment overdue');await review(5,[],require('node:crypto').randomUUID(),true,'No payment dates agreed yet');assert.equal((await inbox()).items.filter(n=>n.source_kind==='expense').length,0);assert.equal((await ledger()).expenses[0].schedule_history.length,3);});
 await t.test('reconciled expenses stay locked and financial schedule history is never directly exposed',async()=>{await payment(500,6);await reconcile(7,true);await assert.rejects(review(8,plan,require('node:crypto').randomUUID()),/Reopen/);await assert.rejects(q('select * from public.cb_expense_schedule_changes'),/permission denied/);});
 }finally{await db.close();}
});
