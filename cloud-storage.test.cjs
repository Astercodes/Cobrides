const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
function device(server,user='u',storage=new Map()){
const identity={user:{id:user}},cache='furbrides-v1:'+user,elements=[];
const node=()=>({style:{},append(){},replaceChildren(){},setAttribute(){},hidden:false});
const A={current:async()=>identity,request:async(path,body)=>{
 if(server.offline)throw Error('Network unavailable');
 const key=user+':'+(body?.p_workspace||'bride');
 if(path.includes('cb_can_seed_demo'))return false;
 if(path.includes('cb_save_workspace')){const old=server.get(key);if((old?.revision||0)!==body.p_revision)throw Error('CB_SYNC_CONFLICT');const revision=(old?.revision||0)+1;server.set(key,{revision,payload:structuredClone(body.p_payload)});return revision;}
 const row=server.get(key);return row?[structuredClone(row)]:[];
}};
const context=vm.createContext({window:{CoBridesAuth:A,addEventListener(){}},document:{body:{dataset:{},append(x){elements.push(x);}},createElement:node,createTextNode:x=>x,addEventListener(){}},location:{pathname:'/journey.html'},localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},setTimeout:()=>1,clearTimeout(){},Blob,URL,confirm:()=>false});
vm.runInContext(fs.readFileSync('cloud-storage.js','utf8'),context);
return {cloud:context.window.CoBridesCloud,identity,storage,cache,elements};
}
test('a second device loads the same account journey and another account remains separate',async()=>{
 const server=new Map(),first=device(server);await first.cloud.open(first.identity);first.cloud.save({profile:{name:'Amara'},tasks:[{title:'Book venue'}]});await first.cloud.flush();
 const second=device(server);await second.cloud.open(second.identity);assert.equal(JSON.parse(second.storage.get(second.cache)).tasks[0].title,'Book venue');
 const stranger=device(server,'other');await stranger.cloud.open(stranger.identity);assert.equal(stranger.storage.get(stranger.cache),undefined);
});
test('stale edits cannot overwrite another device and remain in the durable outbox',async()=>{
 const server=new Map(),a=device(server),b=device(server);await a.cloud.open(a.identity);await b.cloud.open(b.identity);
 a.cloud.save({title:'First device'});await a.cloud.flush();b.cloud.save({title:'Second device'});await b.cloud.flush();
 assert.equal(server.get('u:bride').payload.title,'First device');assert.equal(JSON.parse(b.storage.get('cb-outbox:u:bride')).payload.title,'Second device');assert.equal(b.elements.length,1);
});
test('an interrupted unsynced edit resumes from its stored revision',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);a.cloud.save({title:'Draft to resume'});
 const resumed=device(server,'u',a.storage);await resumed.cloud.open(resumed.identity);await new Promise(resolve=>setImmediate(resolve));
 assert.equal(server.get('u:bride').payload.title,'Draft to resume');assert.equal(a.storage.get('cb-outbox:u:bride'),undefined);
});
test('failed saves remain recoverable and retry after the connection returns',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);server.offline=true;a.cloud.save({title:'Offline edit'});await a.cloud.flush();assert(a.storage.has('cb-outbox:u:bride'));assert(!server.has('u:bride'));server.offline=false;await a.cloud.flush();assert.equal(server.get('u:bride').payload.title,'Offline edit');assert(!a.storage.has('cb-outbox:u:bride'));
});
test('schema restricts reads by owner and exposes writes only through revision-checked RPC',()=>{
 const sql=fs.readFileSync('supabase/cloud-storage.sql','utf8');assert(sql.includes('using(user_id=auth.uid())'));assert(sql.includes('revoke all on public.cb_workspace_states from anon,authenticated'));assert(sql.includes('revision=p_revision'));assert(sql.includes("raise exception 'CB_SYNC_CONFLICT'"));assert(sql.includes('email_confirmed_at is not null'));
});
