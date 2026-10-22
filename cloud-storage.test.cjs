const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
function device(server,user='u',storage=new Map(),search=''){
const identity={user:{id:user}},cache='furbrides-v1:'+user,elements=[];
const node=()=>({style:{},append(){},replaceChildren(){},setAttribute(){},hidden:false});
const A={current:async()=>identity,accountContext:async()=>({defaultDemo:server.demoOwner===user}),request:async(path,body)=>{
 if(server.offline)throw Error('Network unavailable');
 const key=user+':'+(body?.p_workspace||'bride');
 if(path.includes('cb_can_seed_demo'))return false;
 if(path.includes('cb_save_workspace')){if(server.beforeSave)await server.beforeSave(body);const old=server.get(key);if((old?.revision||0)!==body.p_revision)throw Error('CB_SYNC_CONFLICT');const revision=(old?.revision||0)+1;server.set(key,{revision,payload:structuredClone(body.p_payload)});return revision;}
 const row=server.get(key);return row?[structuredClone(row)]:[];
}};
const context=vm.createContext({window:{CoBridesAuth:A,addEventListener(){}},document:{body:{dataset:{},append(x){elements.push(x);}},createElement:node,createTextNode:x=>x,addEventListener(){}},location:{pathname:'/journey.html',search},localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},setTimeout:()=>1,clearTimeout(){},Blob,URL,URLSearchParams,confirm:()=>false});
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
test('the explicit demo journey preserves personal plans and is available from another device',async()=>{
 const server=new Map(),personal=device(server);await personal.cloud.open(personal.identity);personal.cloud.save({profile:{name:'Ayomide'},tasks:[{title:'My own task'}]});await personal.cloud.flush();
 const demo=device(server,'u',new Map(),'?demo=amara-tobi');await demo.cloud.open(demo.identity);assert(demo.cloud.seedDemo);assert(demo.cloud.demoMode);demo.cloud.save({profile:{name:'Amara',partner:'Tobi'},tasks:[{title:'Reception tasting'}]});await demo.cloud.flush();
 const phone=device(server,'u',new Map(),'?demo=amara-tobi');await phone.cloud.open(phone.identity);assert.equal(JSON.parse(phone.storage.get(phone.cloud.cacheKey)).profile.name,'Amara');assert.equal(phone.cloud.seedDemo,false);
 const own=device(server);await own.cloud.open(own.identity);const ownData=JSON.parse(own.storage.get(own.cloud.cacheKey));assert.equal(ownData.profile.name,'Ayomide');assert.equal(ownData.tasks[0].title,'My own task');own.cloud.save({...ownData,updated:true});await own.cloud.flush();assert.equal(server.get('u:bride').payload.demo.profile.partner,'Tobi');
});
test('the designated account opens its demo after a normal login and retains a personal-workspace override',async()=>{
 const server=new Map();server.demoOwner='owner';server.set('owner:bride',{revision:1,payload:{profile:{name:'Ayomide'},tasks:[]}});const login=device(server,'owner');await login.cloud.open(login.identity);assert(login.cloud.demoMode);assert(login.cloud.seedDemo);login.cloud.save({profile:{name:'Amara',partner:'Tobi'},tasks:[{title:'Confirm photographer'}]});await login.cloud.flush();
 const phone=device(server,'owner');await phone.cloud.open(phone.identity);assert.equal(JSON.parse(phone.storage.get(phone.cloud.cacheKey)).profile.name,'Amara');
 const personal=device(server,'owner',new Map(),'?workspace=personal');await personal.cloud.open(personal.identity);assert(!personal.cloud.demoMode);assert.equal(JSON.parse(personal.storage.get(personal.cloud.cacheKey)).profile.name,'Ayomide');const other=device(server,'other');await other.cloud.open(other.identity);assert(!other.cloud.demoMode);
});
test('schema restricts reads by owner and exposes writes only through revision-checked RPC',()=>{
 const sql=fs.readFileSync('supabase/cloud-storage.sql','utf8');assert(sql.includes('using(user_id=auth.uid())'));assert(sql.includes('revoke all on public.cb_workspace_states from anon,authenticated'));assert(sql.includes('revision=p_revision'));assert(sql.includes("raise exception 'CB_SYNC_CONFLICT'"));assert(sql.includes('email_confirmed_at is not null'));
});

test('saving states distinguish queued, saved, failed and conflicting changes',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);assert.equal(a.cloud.status().state,'saved');a.cloud.save({title:'Saved edit'});assert.equal(a.cloud.status().state,'pending');await a.cloud.flush();assert.equal(a.cloud.status().state,'saved');assert.equal(a.cloud.status().pending,false);
 server.offline=true;a.cloud.save({title:'Interrupted'});await a.cloud.flush();assert.equal(a.cloud.status().state,'error');assert.equal(a.cloud.status().pending,true);server.offline=false;await a.cloud.flush();assert.equal(a.cloud.status().state,'saved');
 const b=device(server);await b.cloud.open(b.identity);a.cloud.save({title:'New version'});await a.cloud.flush();b.cloud.save({title:'Old version'});await b.cloud.flush();assert.equal(b.cloud.status().state,'conflict');assert.equal(b.cloud.status().pending,true);
});
test('attachment contents survive a confirmed save and load on another device',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);const file={name:'ceremony.pdf',type:'application/pdf',url:'data:application/pdf;base64,JVBERi0xLjcK'};await a.cloud.commit({documents:[file]});const b=device(server);await b.cloud.open(b.identity);assert.deepEqual(JSON.parse(b.storage.get(b.cache)).documents,[file]);assert.equal(a.cloud.status().pending,false);
});
test('edits made during a save remain queued and use the newly confirmed revision',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);let release;server.beforeSave=()=>new Promise(resolve=>{release=resolve;});a.cloud.save({title:'First'});const flushing=a.cloud.flush();await new Promise(resolve=>setImmediate(resolve));assert.equal(a.cloud.status().state,'saving');a.cloud.save({title:'Latest'});release();await flushing;assert(a.cloud.status().pending);assert.equal(JSON.parse(a.storage.get('cb-outbox:u:bride')).revision,1);server.beforeSave=null;await a.cloud.flush();assert.equal(server.get('u:bride').payload.title,'Latest');assert.equal(server.get('u:bride').revision,2);
});
test('commit rejects connection failures without discarding the recoverable draft',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);server.offline=true;await assert.rejects(a.cloud.commit({title:'Keep me'}),/Network unavailable/);assert(a.storage.has('cb-outbox:u:bride'));assert(a.cloud.status().pending);
});
test('oversized uploads are retained for recovery and never reported as saved',async()=>{
 const server=new Map(),a=device(server);await a.cloud.open(a.identity);a.cloud.save({image:'x'.repeat(19000001)});await a.cloud.flush();assert.equal(a.cloud.status().state,'error');assert.match(a.cloud.status().error,/too many attachments/);assert(!server.has('u:bride'));assert(a.storage.has('cb-outbox:u:bride'));
});
