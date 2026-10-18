/* Account-owned snapshots with a durable outbox and optimistic concurrency. */
(()=>{'use strict';
let session,workspace,cacheKey,outboxKey,revision=0,pending=null,saving=false,conflict=false,timer,notice,ready=false;
const A=window.CoBridesAuth;
function read(key){try{return JSON.parse(localStorage.getItem(key)||'null');}catch{return null;}}
function show(text,blocked=false){if(!notice){notice=document.createElement('aside');notice.setAttribute('role','status');notice.style.cssText='position:fixed;bottom:18px;right:18px;z-index:10000;background:white;color:black;border:1px solid #ed007e;border-radius:14px;padding:12px 16px;max-width:360px;box-shadow:0 8px 32px #0002;font:14px system-ui';document.body.append(notice);}notice.replaceChildren(document.createTextNode(text));notice.hidden=false;if(blocked){for(const [title,action] of [['Download my changes',download],['Load latest saved version',()=>{if(confirm('Download your changes first if you want to keep them. Load the latest cloud version?')){localStorage.removeItem(outboxKey);location.reload();}}]]){const button=document.createElement('button');button.textContent=title;button.style.cssText='display:block;margin-top:10px;border-radius:8px;padding:8px';button.onclick=action;notice.append(button);}}}
function download(){const draft=pending||read(outboxKey)?.payload;if(!draft)return;const link=document.createElement('a'),url=URL.createObjectURL(new Blob([JSON.stringify(draft,null,2)],{type:'application/json'}));link.href=url;link.download='cobrides-unsynced-changes.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
async function open(identity){workspace=location.pathname==='/journey.html'?'bride':document.body.dataset.participant;if(!workspace||workspace==='admin')return;
session=identity;cacheKey=workspace==='bride'?'furbrides-v1:'+identity.user.id:'furbrides-participant-v1:'+identity.user.id+':'+workspace;outboxKey='cb-outbox:'+identity.user.id+':'+workspace;
let rows;try{rows=await A.request('/rest/v1/cb_workspace_states?select=payload,revision&workspace=eq.'+encodeURIComponent(workspace)+'&user_id=eq.'+encodeURIComponent(identity.user.id),null,session);}catch(error){throw Error('Your cloud workspace could not load. '+(error.status===404?'The cloud-storage database setup is required.':error.message));}
const remote=rows[0],draft=read(outboxKey);revision=remote?.revision||0;
if(draft){pending=draft.payload;if(draft.revision!==revision){conflict=true;show('Another device saved a newer version. Your changes are preserved on this device.',true);}else if(pending)localStorage.setItem(cacheKey,JSON.stringify(pending));}
if(remote&&!pending)localStorage.setItem(cacheKey,JSON.stringify(remote.payload));
window.CoBridesCloud.seedDemo=!remote&&!pending&&workspace==='bride'&&await A.request('/rest/v1/rpc/cb_can_seed_demo',{},session);
if(conflict)localStorage.setItem(cacheKey,JSON.stringify(draft.payload));
ready=true;if(pending&&!conflict)void flush();
}
function save(payload){if(!ready)return;pending=JSON.parse(JSON.stringify(payload));try{localStorage.setItem(outboxKey,JSON.stringify({revision,payload:pending}));}catch{show('Device backup is full. Keep this page open until cloud saving completes.');}if(conflict)return;clearTimeout(timer);timer=setTimeout(flush,600);}
async function flush(){timer=null;if(!ready||saving||!pending||conflict)return;saving=true;const snapshot=pending;show('Saving your changes…');try{const verified=await A.current();if(!verified||verified.user.id!==session.user.id)throw Error('Sign in again to save your changes.');session=verified;revision=await A.request('/rest/v1/rpc/cb_save_workspace',{p_workspace:workspace,p_payload:snapshot,p_revision:revision},session);if(pending===snapshot){pending=null;localStorage.removeItem(outboxKey);if(notice)notice.hidden=true;}else localStorage.setItem(outboxKey,JSON.stringify({revision,payload:pending}));}catch(error){if(/CB_SYNC_CONFLICT/.test(error.message)){conflict=true;show('Another device saved newer changes. Your edits are preserved here.',true);}else{show('Changes are waiting to sync. '+error.message);clearTimeout(timer);timer=setTimeout(flush,15000);}}finally{saving=false;if(pending&&!conflict&&!timer)timer=setTimeout(flush,600);}}
window.addEventListener('online',()=>{timer=null;void flush();});
window.addEventListener('beforeunload',event=>{if(pending){event.preventDefault();event.returnValue='';}});
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden'){timer=null;void flush();}});
window.CoBridesCloud={open,save,flush,seedDemo:false};
})();
