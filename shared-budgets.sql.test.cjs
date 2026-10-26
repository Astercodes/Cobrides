const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('shared budgets forecast commitments and reviewed unbooked estimates',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');const reportSql=fs.readFileSync('supabase/financial-reports.sql','utf8');await db.exec(reportSql);await db.exec(reportSql);await as(0);
 expense=await connect();const paid=await payment(300,1);await payment(100,2,'Refund',paid.payment);await q("select public.cb_adjust_expense_settlement($1,3,gen_random_uuid(),800,'Revised agreement',true)",[expense.id]);
 const quote2=(await one("select public.cb_save_vendor_quote($1,null,gen_random_uuid(),0,$2) data",[vendor.id,{title:'USD extras',currency:'USD',amount:100,tax:0,service:0,delivery:0,status:'Received'}])).data;
 const booking2=(await one("select public.cb_save_vendor_booking($1,null,$2,1,gen_random_uuid(),0,$3,true) data",[vendor.id,quote2.id,{title:'Extras',status:'Confirmed',milestones:[]}])).data;
 const e2=(await one('select public.cb_connect_booking_expense($1,1,gen_random_uuid()) data',[booking2.id])).data;
 await q('select public.cb_record_shared_payment($1,1,gen_random_uuid(),$2)',[e2.id,{kind:'Payment',amount:50,date:'2026-01-01',method:'Cash'}]);
 const report=async()=>(await one('select public.cb_shared_financial_report($1) data',[project.id])).data;

 await db.exec('reset role');const sqlBudget=fs.readFileSync('supabase/shared-budgets.sql','utf8');await db.exec(sqlBudget);await db.exec(sqlBudget);await as(0);
 const budget=async()=>(await one('select public.cb_shared_budget($1) data',[project.id])).data,budgetClient=require('node:crypto').randomUUID(),plan={decor:{target:1200,unbooked:250},other:{target:300,unbooked:50}};
 const save=async(rev=0,p=plan,target=2000,reserve=200,key=budgetClient)=>(await one("select public.cb_save_shared_budget($1,'NGN',$2,$3,$4,$5,$6) data",[project.id,rev,key,target,reserve,p])).data;
 await t.test('financial access is explicit and native currency budgets do not combine totals',async()=>{for(const i of [1,2,3]){await as(i);await assert.rejects(budget(),/Financial access/);await assert.rejects(save(),/financial access/);}await as(0);await save();const data=await budget();assert.equal(data.totals.length,2);const ngn=data.totals.find(t=>t.currency==='NGN');assert.equal(ngn.committed,800);assert.equal(ngn.paid,200);assert.equal(ngn.unbooked,300);assert.equal(ngn.forecast,1300);assert.equal(ngn.headroom,700);assert.equal(data.totals.find(t=>t.currency==='USD').target,null);});
 await t.test('versioned budgets reject conflicting edits and allocations beyond the target',async()=>{assert.equal((await save()).revision,1);await assert.rejects(save(0,plan,2100),e=>e.code==='PT409');await assert.rejects(save(1,plan,1000,200,require('node:crypto').randomUUID()),/exceed the overall/);await assert.rejects(save(1,{unknown:{target:1,unbooked:0}},2000,200,require('node:crypto').randomUUID()),/valid category/);await assert.rejects(save(1,{decor:{target:1,unbooked:-1}},2000,200,require('node:crypto').randomUUID()),/nonnegative/);});
 await t.test('explicit expense categories move commitments without changing payments',async()=>{const key=require('node:crypto').randomUUID();await q("select public.cb_set_budget_category($1,'decor',0,$2)",[expense.id,key]);await q("select public.cb_set_budget_category($1,'decor',0,$2)",[expense.id,key]);const data=await budget(),decor=data.categories.find(c=>c.currency==='NGN'&&c.category==='decor'),other=data.categories.find(c=>c.currency==='NGN'&&c.category==='other');assert.equal(decor.committed,800);assert.equal(decor.paid,200);assert.equal(other.committed,0);await assert.rejects(q("select public.cb_set_budget_category($1,'other',0,gen_random_uuid())",[expense.id]),e=>e.code==='PT409');assert.equal((await report()).totals.find(t=>t.currency==='NGN').net_paid,200);await assert.rejects(q('select * from public.cb_shared_budgets'),/permission denied/);});
 }finally{await db.close();}
});
