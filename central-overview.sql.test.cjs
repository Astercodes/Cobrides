const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('Central reads canonical records with live access and no private guest or finance leakage',{skip:!process.env.CB_PGLITE_PATH},async()=>{
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

 const names=['shared-ledger','expense-settlements','expense-reminders','expense-schedules','financial-reports','expense-files','shared-contributions','contribution-notifications','support-allocations','shared-budgets','shared-shopping'];await db.exec('reset role');for(const name of names)await db.exec(fs.readFileSync('supabase/'+name+'.sql','utf8'));await as(0);
 const uuid=()=>require('node:crypto').randomUUID();const vendor=(await one("select public.cb_save_shared_vendor($1,null,$2,'retail-check',0,'Petal Studio','{}',array[]::uuid[],false) data",[project.id,uuid()])).data;
 const quote=(await one('select public.cb_save_vendor_quote($1,null,$2,0,$3) data',[vendor.id,uuid(),{title:'Venue flowers',currency:'NGN',amount:1000,tax:0,service:0,delivery:0,status:'Received'}])).data;
 const booking=(await one('select public.cb_save_vendor_booking($1,null,$2,1,$3,0,$4,true) data',[vendor.id,quote.id,uuid(),{title:'Flower booking',scope:'Reception flowers',status:'Confirmed',milestones:[]}])).data;
 const booked=(await one('select public.cb_connect_booking_expense($1,1,$2) data',[booking.id,uuid()])).data;
 await db.exec('reset role');const migrationRetail=fs.readFileSync('supabase/retail-expenses.sql','utf8');await db.exec(migrationRetail);await db.exec(migrationRetail);await as(0);

await db.exec('reset role');for(const f of ['wedding-publication','guest-rsvp','shared-experience','experience-run-show','experience-issues','central-overview']){const csql=fs.readFileSync('supabase/'+f+'.sql','utf8');await db.exec(csql);await db.exec(csql);}await as(0);
event=await one("select * from public.cb_save_project_event($1,'reception',0,'Reception','{}','restricted')",[project.id]);await q("select public.cb_save_shared_task($1,'central-task',0,'Confirm venue','bride@example.com','2027-01-01','task','PRIVATE TASK NOTES')",[project.id]);
await db.exec('reset role');await q("update public.cb_projects set details=$2 where id=$1",[project.id,{date:'2027-06-20',dateStatus:'Confirmed'}]);await q("insert into public.cb_rsvp_households(project_id,created_by,local_ref,data,answers,revoked) values($1,$2,'central-household',$3,$4,true)",[project.id,ids[0],{title:'PRIVATE FAMILY',contact:'private@example.com',members:[{id:'guest-a',name:'PRIVATE GUEST',events:[event.id]}]},[{guest:'guest-a',event:event.id,status:'Confirmed',diet:'PRIVATE DIET'}]]);await as(0);
const read=()=>one('select public.cb_central_overview($1) v',[project.id]).then(r=>r.v);let result=await read();assert.equal(result.date,'2027-06-20');assert.equal(result.tasks.length,1);assert(!JSON.stringify(result).includes('PRIVATE'));assert.equal(result.guests.find(g=>g.event===event.id).Confirmed,1);assert(result.can_finance);const canonical=(await one('select public.cb_shared_budget($1) v',[project.id])).v;assert.deepEqual(result.budget.totals,canonical.totals);assert(!Object.hasOwn(result.budget,'expenses'));assert.equal(result.events.length,1);
await as(1);result=await read();assert.equal(result.can_finance,false);assert.equal(result.budget,null);assert.deepEqual(result.payments,[]);await as(2);result=await read();assert.equal(result.tasks.length,0);assert.equal(result.events.length,0);assert.equal(result.can_guests,false);assert.deepEqual(result.guests,[]);assert.equal(result.budget,null);await as(0);await q('select public.cb_set_event_member($1,$2,true)',[event.id,ids[2]]);await as(2);assert.equal((await read()).events.length,1);
await db.exec('reset role');await q("insert into public.cb_collab_access(project_id,user_id,expires_at) values($1,$2,now()-interval '1 hour')",[project.id,ids[2]]);await as(2);await assert.rejects(read(),/Wedding access/);await as(3);await assert.rejects(read(),/Wedding access/);await db.exec('set role anon');await assert.rejects(read(),/permission denied/);
}finally{await db.close();}});
