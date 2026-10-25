const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('financial attachments protect files, ownership and cleanup',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');const filesSql=fs.readFileSync('supabase/expense-files.sql','utf8');await db.exec(filesSql);await db.exec(filesSql);await as(0);
 const path=ids[0]+'/receipts/proof.pdf',path2=ids[0]+'/receipts/invoice.pdf';await db.exec('reset role');for(const p of [path,path2])await q("insert into storage.objects(bucket_id,name,metadata) values('cb-documents',$1,jsonb_build_object('mimetype','application/pdf','size',123))",[p]);await as(0);
 const list=async()=>(await one('select public.cb_list_expense_files($1) data',[expense.id])).data;
 const link=async(p=path,pay=null)=>(await one("select public.cb_link_expense_file($1,$2,$3,'Vendor invoice.pdf','Invoice') data",[expense.id,pay,p])).data;
 let file;
 await t.test('only financial editors can attach own uploaded documents',async()=>{for(const i of [1,2,3]){await as(i);await assert.rejects(list(),/Financial access/);await assert.rejects(link(),/financial access/);}await as(0);await assert.rejects(link(ids[1]+'/receipt.pdf'),/own file/);await assert.rejects(link(path,booking.id),/payment from this expense/);file=await link();assert.equal((await link()).id,file.id);assert.equal((await list()).files.length,1);await assert.rejects(q('select * from public.cb_expense_files'),/permission denied/);});
 await t.test('file policies grant financial access only and revoke immediately',async()=>{await q("select public.cb_set_project_member($1,$2,'planner',true)",[project.id,ids[1]]);await as(1);assert.equal((await list()).files.length,1);assert.equal((await one("select count(*)::int n from storage.objects where name=$1",[path])).n,1);await as(2);assert.equal((await one("select count(*)::int n from storage.objects where name=$1",[path])).n,0);await as(0);await q("select public.cb_set_project_member($1,$2,'planner',false)",[project.id,ids[1]]);await as(1);assert.equal((await one("select count(*)::int n from storage.objects where name=$1",[path])).n,0);await as(0);});
 await t.test('payment proof validates membership, refuses unsafe types and honors cleanup locks',async()=>{const p=await payment(300,1);assert.equal((await link(path2,p.payment)).payment_id,p.payment);await db.exec('reset role');await q("insert into public.cb_file_reservations(bucket,path,deleting) values('cb-documents',$1,true)",[path]);await as(0);await assert.rejects(link(),/cleanup/);await db.exec('reset role');await q('delete from public.cb_file_reservations where path=$1',[path]);await q("insert into storage.objects values('cb-documents',$1,jsonb_build_object('mimetype','text/html'))",[ids[0]+'/bad.html']);await as(0);await assert.rejects(link(ids[0]+'/bad.html'),/PDF/);});
 await t.test('removal hides access but protects cleanup for thirty days and supports reattachment',async()=>{await q('select public.cb_remove_expense_file($1)',[file.id]);assert.equal((await list()).files.length,1);await db.exec('reset role');assert.equal((await one("select public.cb_file_referenced('cb-documents',$1) used",[path])).used,true);await q("update public.cb_expense_files set removed_at=now()-interval '31 days' where id=$1",[file.id]);assert.equal((await one("select public.cb_file_referenced('cb-documents',$1) used",[path])).used,false);await as(0);await link();assert.equal((await list()).files.length,2);});
 }finally{await db.close();}
});
