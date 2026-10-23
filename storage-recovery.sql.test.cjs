const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('PostgreSQL storage allowance, RLS, cleanup protection and revision recovery',{skip:!process.env.CB_PGLITE_PATH},async t=>{
 const {PGlite}=require(process.env.CB_PGLITE_PATH),db=new PGlite();
 const a='11111111-1111-4111-8111-111111111111',b='22222222-2222-4222-8222-222222222222';
 const query=(sql,args)=>db.query(sql,args),one=async(sql,args)=>(await query(sql,args)).rows[0];
 try{
 await db.exec(`create role anon; create role authenticated; create schema auth; create schema storage;
 create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.user',true),'')::uuid$$;
 insert into auth.users values('${a}','a@example.com',now()),('${b}','b@example.com',now());
 create table storage.objects(bucket_id text,name text,metadata jsonb,created_at timestamptz default now(),primary key(bucket_id,name));
 alter table storage.objects enable row level security;
 grant usage on schema public,auth,storage to authenticated; grant select,insert,delete on storage.objects to authenticated;
 create policy owner_read on storage.objects for select to authenticated using(split_part(name,'/',1)=auth.uid()::text);`);
 await db.exec(fs.readFileSync('supabase/cloud-storage.sql','utf8'));
 const migration=fs.readFileSync('supabase/storage-recovery.sql','utf8');await db.exec(migration);await db.exec(migration);
 const as=async uid=>{await db.exec('reset role');await query("select set_config('app.user',$1,false)",[uid]);await db.exec('set role authenticated');};
 const reserve=(path,size=100)=>one("select public.cb_reserve_file('cb-inspiration',$1,$2) as result",[path,size]);
 const save=(payload,revision)=>one("select public.cb_save_workspace('bride',$1::jsonb,$2) as revision",[JSON.stringify(payload),revision]);
 await as(a);
 await t.test('reservations deduplicate, exclude other accounts and enforce real insert metadata',async()=>{
  await reserve(a+'/photo');await reserve(a+'/photo');assert.equal((await one('select public.cb_storage_status() as result')).result.reserved,100);
  await assert.rejects(reserve(b+'/photo'),/Invalid upload/);
  await assert.rejects(query('insert into storage.objects values($1,$2,$3,now())',['cb-inspiration',a+'/photo',{size:200}]),/row-level security/);
  await query('insert into storage.objects values($1,$2,$3,now())',['cb-inspiration',a+'/photo',{size:100}]);
  assert.equal((await one('select public.cb_storage_status() as result')).result.used,100);
 });
 const ref='cb-file:v1:cb-inspiration/'+a+'/photo';
 await t.test('saved references must exist and belong to this account',async()=>{
  await assert.rejects(save({image:'cb-file:v1:cb-inspiration/'+b+'/photo'},0),/unavailable/);
  await assert.rejects(save({image:'cb-file:v1:cb-inspiration/'+a+'/missing'},0),/unavailable/);
  assert.equal((await save({nested:{images:[ref]},name:'first'},0)).revision,1);
  assert.equal((await save({name:'second'},1)).revision,2);
  await assert.rejects(save({name:'stale'},1),/CB_SYNC_CONFLICT/);
 });
 await t.test('backups are owner-only, restore uses CAS and retains the replaced version',async()=>{
  const rows=(await query('select revision,payload from public.cb_workspace_backups')).rows;assert.equal(rows.length,1);assert.equal(rows[0].payload.name,'first');
  await as(b);assert.equal((await query('select * from public.cb_workspace_backups')).rows.length,0);
  await assert.rejects(query("select public.cb_restore_workspace('bride',1,2)"),/not found/);
  await as(a);await assert.rejects(query("select public.cb_restore_workspace('bride',1,1)"),/CB_SYNC_CONFLICT/);
  assert.equal((await one("select public.cb_restore_workspace('bride',1,2) as revision")).revision,3);
  assert.equal((await one("select payload from public.cb_workspace_states where workspace='bride'")).payload.name,'first');
  assert.equal((await one('select payload from public.cb_workspace_backups where revision=2')).payload.name,'second');
 });
 await t.test('500 MB allowance includes existing files and isolates accounts',async()=>{
  await db.exec('reset role');for(let i=0;i<25;i++)await query('insert into storage.objects values($1,$2,$3,now())',['cb-documents',a+'/large'+i,{size:20971520}]);
  await as(a);await assert.rejects(reserve(a+'/over',1),/allowance is full/);
  await as(b);await reserve(b+'/own',10);assert.equal((await one('select public.cb_storage_status() as result')).result.reserved,10);
 });
 await t.test('cleanup ignores young, current and backup files; claims block resurrecting deleted files',async()=>{
  await db.exec('reset role');await query("insert into storage.objects values('cb-inspiration',$1,'{\"size\":100}',now()-interval '40 days')",[a+'/orphan']);
  await query("update storage.objects set created_at=now()-interval '40 days' where name=$1",[a+'/photo']);
  await query("update public.cb_file_reservations set touched_at=now()-interval '40 days' where path=$1",[a+'/photo']);
  await as(a);const candidates=(await query('select * from public.cb_claim_unused_files()')).rows;assert.deepEqual(candidates,[{bucket:'cb-inspiration',path:a+'/orphan'}]);
  assert.equal((await one('select public.cb_file_delete_allowed($1,$2) as allowed',['cb-inspiration',a+'/photo'])).allowed,false);
  await assert.rejects(save({image:'cb-file:v1:cb-inspiration/'+a+'/orphan'},3),/unavailable/);
  await assert.rejects(reserve(a+'/orphan'),/cleanup is in progress/);
  await as(b);assert.equal((await one('select public.cb_file_delete_allowed($1,$2) as allowed',['cb-inspiration',a+'/orphan'])).allowed,false);
  await as(a);assert.equal((await one('select public.cb_file_delete_allowed($1,$2) as allowed',['cb-inspiration',a+'/orphan'])).allowed,true);
 });
 }finally{await db.close();}
});
