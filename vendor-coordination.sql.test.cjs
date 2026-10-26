const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('vendor coordination restricts operational work to managers and assigned teammates',{skip:!process.env.CB_PGLITE_PATH},async t=>{
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

 await db.exec('reset role');const sqlWork=fs.readFileSync('supabase/vendor-coordination.sql','utf8');await db.exec(sqlWork);await db.exec(sqlWork);await as(0);
 const vendor=(await one("select public.cb_save_shared_vendor($1,null,gen_random_uuid(),'work-vendor',0,'Petal Studio','{}',array[$2]::uuid[],false) data",[project.id,ids[2]])).data;
 const details={title:'Reception floral setup',kind:'Setup',assignedTo:ids[2],due:'2027-01-15',timeWindow:'7-9 a.m. WAT',location:'Reception hall',instructions:'Install floral arch before photography.',status:'To do',progressNote:''},key=require('node:crypto').randomUUID();let work;
 const save=async(id=null,rev=0,data=details,c=key)=>(await one('select public.cb_save_vendor_work($1,$2,$3,$4,$5) data',[vendor.id,id,rev,c,data])).data;
 const list=async()=>(await one('select public.cb_vendor_coordination($1) data',[vendor.id])).data;
 const progress=async(rev,status,note='',c=require('node:crypto').randomUUID())=>(await one('select public.cb_update_vendor_progress($1,$2,$3,$4,$5) data',[work.id,rev,c,status,note])).data;
 await t.test('planning managers do not need financial access to coordinate vendors',async()=>{await as(1);work=await save();assert.equal(work.title,details.title);assert.equal((await save()).id,work.id);await save(null,0,{...details,title:'Private planner handoff',assignedTo:ids[1]},require('node:crypto').randomUUID());assert.equal((await list()).items.length,2);await as(0);});
 await t.test('vendors see only assigned work and cannot change service instructions',async()=>{await as(2);const data=await list();assert.equal(data.items.length,1);assert.equal(data.people.length,0);assert.equal(data.editable,false);assert.equal(data.items[0].can_update,true);assert(!JSON.stringify(data).includes('Private planner handoff'));await assert.rejects(save(work.id,1,details,require('node:crypto').randomUUID()),/Planning access/);await as(3);await assert.rejects(list(),/Vendor access/);await as(0);});
 await t.test('assigned progress updates are versioned and require blocker/completion details',async()=>{await as(2);await assert.rejects(progress(1,'Blocked'),/explain/);const key=require('node:crypto').randomUUID();work=await progress(1,'Blocked','Venue access delayed',key);assert.equal(work.revision,2);assert.equal((await progress(1,'Blocked','Venue access delayed',key)).revision,2);await assert.rejects(progress(1,'Ready','Setup ready'),e=>e.code==='PT409');work=await progress(2,'Complete','Floral installation approved by planner');await assert.rejects(progress(3,'In progress','Reopening'),/reopen/);await as(0);});
 await t.test('reassignment revokes old work access and history remains operational only',async()=>{work=await save(work.id,3,{...details,assignedTo:ids[1],status:'In progress'},require('node:crypto').randomUUID());assert.equal((await list()).items.find(w=>w.id===work.id).history.length,4);await as(2);assert.equal((await list()).items.length,0);await assert.rejects(progress(4,'Ready','Ready'),/Assigned work access/);await as(0);await assert.rejects(save(null,0,{...details,assignedTo:ids[3]},require('node:crypto').randomUUID()),/accepted teammate/);await assert.rejects(q('select * from public.cb_vendor_work'),/permission denied/);});
 }finally{await db.close();}
});
