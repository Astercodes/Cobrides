const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),crypto=require('node:crypto'),C=require('./workspace-record-core');
test('record migration, atomic staged saves, ownership, recovery and large workspaces',{skip:!process.env.CB_PGLITE_PATH},async t=>{
 const {PGlite}=require(process.env.CB_PGLITE_PATH),db=new PGlite(),a='11111111-1111-4111-8111-111111111111',b='22222222-2222-4222-8222-222222222222';
 const query=(sql,args)=>db.query(sql,args),one=async(sql,args)=>(await query(sql,args)).rows[0];
 const as=async uid=>{await db.exec('reset role');await query("select set_config('app.user',$1,false)",[uid]);await db.exec('set role authenticated');};
 const begin=async(changes,rev,replace=false)=>{const id=crypto.randomUUID();await query("select public.cb_begin_record_save('bride',$1,$2,$3,$4,$5)",[id,rev,changes.length,'a'.repeat(64),replace]);return id;};
 const stage=async(id,changes)=>{for(const page of C.batches(changes))await query('select public.cb_stage_record_save($1,$2::jsonb)',[id,JSON.stringify(page)]);};
 const commit=async id=>(await one('select public.cb_commit_record_save($1) as revision',[id])).revision;
 const read=async rev=>{const rows=(await query("select record_key,body from public.cb_workspace_records where workspace='bride' and from_revision<=$1 and (to_revision is null or to_revision>$1)",[rev])).rows;return C.decode(new Map(rows.map(r=>[r.record_key,r.body])));};
 try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create schema storage;
 create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.user',true),'')::uuid$$;
 insert into auth.users values('${a}','a@example.com',now()),('${b}','b@example.com',now());
 create table storage.objects(bucket_id text,name text,metadata jsonb,created_at timestamptz default now(),primary key(bucket_id,name));
 grant usage on schema public,auth,storage to authenticated;`);
 await db.exec(fs.readFileSync('supabase/cloud-storage.sql','utf8'));await db.exec(fs.readFileSync('supabase/storage-recovery.sql','utf8'));
 const legacy={cbWorkspaceEnvelope:1,personal:{profile:{name:'Ayomide'},guests:[{id:'g1',name:'Ada'}]},demo:{profile:{name:'Amara'},visions:[{id:'v1',title:'Étoile, sunset'}]}};
 await as(a);await query("select public.cb_save_workspace('bride',$1,0)",[legacy]);
 const migration=fs.readFileSync('supabase/workspace-records.sql','utf8');await db.exec('reset role');await db.exec(migration);await db.exec(migration);await as(a);
 let current=C.encode(legacy),revision=1;
 await t.test('legacy state remains readable until every record is staged and committed',async()=>{
  const changes=C.diff(new Map(),current),id=await begin(changes,1,true);await stage(id,changes.slice(0,1));await assert.rejects(commit(id),/incomplete/);
  assert.deepEqual((await one("select payload from public.cb_workspace_states where workspace='bride'")).payload,legacy);
  await stage(id,changes);revision=await commit(id);assert.equal(revision,2);assert.deepEqual(await read(2),legacy);assert.equal(await commit(id),2);
  assert.deepEqual((await one("select payload from public.cb_workspace_backups where revision=1")).payload,legacy);
  await assert.rejects(query("select public.cb_save_workspace('bride','{}',2)"),/upgraded/);
 });
 await t.test('changes and deletions update only affected records and stale commits fail atomically',async()=>{
  const nextValue=structuredClone(legacy);nextValue.personal.guests.push({id:'g2',name:'Tunde'});nextValue.demo.visions=[];
  const next=C.encode(nextValue),changes=C.diff(current,next),id=await begin(changes,revision),stale=await begin(changes,revision);await stage(id,changes);await stage(stale,changes);
  revision=await commit(id);await assert.rejects(commit(stale),/CB_SYNC_CONFLICT/);assert.deepEqual(await read(revision),nextValue);assert.deepEqual(await read(2),legacy);current=next;
 });
 await t.test('another account cannot read records, stage someone else’s save or access internal functions',async()=>{
  const changes=[{key:'example',deleted:true}],id=await begin(changes,revision);await as(b);
  assert.equal((await query('select * from public.cb_workspace_records')).rows.length,0);
  await assert.rejects(stage(id,changes),/expired/);await assert.rejects(query("select public.cb_save_workspace_legacy('bride','{}',0)"),/permission denied/);
  await as(a);
 });
 await t.test('legacy and record-based backups both restore through record saving',async()=>{
  await db.exec('reset role');await query("insert into public.cb_workspace_backups(user_id,workspace,revision,payload) values($1,'bride',2,'{\"cbRecordStore\":1}') on conflict do nothing",[a]);await as(a);
  revision=(await one("select public.cb_restore_workspace('bride',2,$1) as revision",[revision])).revision;assert.deepEqual(await read(revision),legacy);
  revision=(await one("select public.cb_restore_workspace('bride',1,$1) as revision",[revision])).revision;assert.deepEqual(await read(revision),legacy);current=C.encode(legacy);
  const sqlRows=(await query("select record_key,body from public.cb_workspace_records where to_revision is null")).rows;
  assert.equal(C.diff(new Map(sqlRows.map(r=>[r.record_key,r.body])),current).length,0);
 });
 await t.test('a workspace above 19 MB saves as small records and reopens losslessly',async()=>{
  const large={profile:{name:'Large workspace'},visions:Array.from({length:60},(_,i)=>({id:'idea-'+i,note:'x'.repeat(340000)}))};assert(Buffer.byteLength(JSON.stringify(large))>19000000);
  const next=C.encode(large),changes=C.diff(current,next),pages=C.batches(changes);assert(pages.length>1);assert(pages.every(page=>Buffer.byteLength(JSON.stringify(page))<700000));
  const id=await begin(changes,revision);await stage(id,changes);revision=await commit(id);const result=await read(revision);assert.equal(result.visions.length,60);assert.equal(result.visions[59].note.length,340000);
  assert.deepEqual((await one("select payload from public.cb_workspace_states where workspace='bride'")).payload,{cbRecordStore:1});
 });
 }finally{await db.close();}
});
