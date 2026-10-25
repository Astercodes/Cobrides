const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('contribution notifications preserve sponsor privacy and delivery preferences',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');for(const file of ['shared-contributions','contribution-notifications']){const sql=fs.readFileSync('supabase/'+file+'.sql','utf8');await db.exec(sql);await db.exec(sql);}await as(0);
 const data={title:'Reception support',sponsor:'Aunt Ada',contributor:ids[2],currency:'NGN',amount:1000,kind:'Cash',due:new Date().toISOString().slice(0,10),notes:'Shared pledge',status:'Active'};
 const pledge=(await one('select public.cb_save_contribution($1,null,0,gen_random_uuid(),$2) data',[project.id,data])).data;
 const notices=async()=>(await inbox()).items.filter(n=>n.source_kind==='contribution');let receipt;
 await t.test('assigned sponsors receive generic notices and unrelated team members receive none',async()=>{await as(2);const rows=await notices();assert.equal(rows.length,2);assert(rows.some(n=>n.title==='Contribution expected today'));assert(!JSON.stringify(rows).includes('1000'));await notices();await db.exec('reset role');assert.equal((await one("select count(*)::int n from public.cb_planning_notifications where user_id=$1 and source_kind='contribution'",[ids[2]])).n,2);await as(1);assert.equal((await notices()).length,0);await as(0);});
 await t.test('receipt and correction notices reflect current receipt state without duplicate pledge updates',async()=>{receipt=(await one("select public.cb_record_contribution_receipt($1,1,gen_random_uuid(),100,'2026-01-01','Confirmed') data",[pledge.id])).data;await as(2);let rows=await notices();assert(rows.some(n=>n.title==='A contribution receipt was recorded'));assert(!rows.some(n=>n.kind.startsWith('contribution_updated:')));await as(0);await q("select public.cb_void_contribution_receipt($1,2,gen_random_uuid(),'Duplicate receipt')",[receipt.receipt]);await as(2);rows=await notices();assert(rows.some(n=>n.title==='A contribution receipt was corrected'));assert(!rows.some(n=>n.title==='A contribution receipt was recorded'));await as(0);});
 await t.test('preferences and existing email consent gate delivery',async()=>{await as(2);await q("select public.cb_set_planning_preferences(array['deadlines'],'UTC')");assert.equal((await notices()).length,1);await db.exec('reset role');assert.equal((await one("select * from public.cb_planning_digest_items($1,now()-interval '1 day',now())",[ids[2]])).quantity,0);await q('update public.cb_planning_preferences set email_opt_in=true where user_id=$1',[ids[2]]);assert.equal((await one("select * from public.cb_planning_digest_items($1,now()-interval '1 day',now())",[ids[2]])).quantity,1);await as(0);});
 await t.test('fully received pledges and revoked membership remove stale reminders',async()=>{await q("select public.cb_record_contribution_receipt($1,3,gen_random_uuid(),1000,'2026-01-01','All support received')",[pledge.id]);await as(2);assert.equal((await notices()).length,0);await as(0);await q('select public.cb_remove_member($1,$2)',[project.id,ids[2]]);await as(2);assert.equal((await notices()).length,0);await as(0);});
 }finally{await db.close();}
});
