'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
test('the manifest launches the authenticated workspace and all icons exist',()=>{
 const m=JSON.parse(fs.readFileSync('manifest.webmanifest'));assert.equal(m.name,'Cobridey');
 assert.equal(m.start_url,'/journey.html#home');assert.equal(m.display,'standalone');
 for(const icon of m.icons){const png=fs.readFileSync('.'+icon.src);assert.equal(png.toString('hex',0,8),'89504e470d0a1a0a');const size=Number(icon.sizes.split('x')[0]);assert.equal(png.readUInt32BE(16),size);assert.equal(png.readUInt32BE(20),size);}
 for(const page of ['index.html','login.html','signup.html','auth-callback.html','journey.html','documents.html'])assert.match(fs.readFileSync(page,'utf8'),/rel="manifest" href="\/manifest.webmanifest"/);
});
for(const existing of [undefined,{active:{scriptURL:'https://www.cobridey.com/offline-worker.js'}}])test('installation preserves an existing offline worker: '+!!existing,async()=>{
 let load,registered;vm.runInNewContext(fs.readFileSync('app-install.js','utf8'),{
  window:{isSecureContext:true,addEventListener:(event,fn)=>{if(event==='load')load=fn;}},
  navigator:{serviceWorker:{getRegistration:async()=>existing,register:async(url)=>{registered=url;}}}
 });await load();assert.equal(registered,existing?undefined:'/app-worker.js');
});
test('offline fallback applies only to failed same-origin page navigations and never caches account responses',async()=>{
 const handlers={},puts=[],fallback={offline:true};let online=true,original;
 vm.runInNewContext(fs.readFileSync('app-worker.js','utf8'),{
  URL,Response,self:{location:{origin:'https://www.cobridey.com'},addEventListener:(name,fn)=>{handlers[name]=fn;}},
  fetch:async request=>{if(!online)throw Error('offline');return original={request,status:200};},
  caches:{open:async()=>({match:async key=>{assert.equal(key,'/app-offline.html');return fallback;},put:(...args)=>puts.push(args)})}
 });
 function navigate(url,method='GET',mode='navigate'){let result;handlers.fetch({request:{url,method,mode},respondWith:value=>{result=value;}});return result;}
 assert.equal(await navigate('https://www.cobridey.com/journey.html'),original);
 online=false;assert.equal(await navigate('https://www.cobridey.com/journey.html'),fallback);
 assert.equal(navigate('https://www.cobridey.com/api/account-context'),undefined);
 assert.equal(navigate('https://project.supabase.co/rest/v1/cb_profiles'),undefined);
 assert.equal(navigate('https://www.cobridey.com/api/workspace-config','GET','cors'),undefined);
 assert.equal(navigate('https://www.cobridey.com/journey.html','POST'),undefined);
 assert.equal(puts.length,0);
});
