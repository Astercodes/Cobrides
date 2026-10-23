/* Account-scoped recovery and Storage API cleanup; no service credentials. */
(()=>{'use strict';
const A=window.CoBridesAuth,buckets=['cb-inspiration','cb-documents','cb-memories'];
let mounted=false,dialog,generation=0;
async function identity(){const s=await A.current();if(!s)throw Error('Sign in again to manage your saved files.');return s;}
async function usage(){return A.request('/rest/v1/rpc/cb_storage_status',{},await identity());}
async function cleanup(){const s=await identity(),files=await A.request('/rest/v1/rpc/cb_claim_unused_files',{},s);let removed=0;
 for(const bucket of buckets){const paths=files.filter(f=>f.bucket===bucket&&f.path.startsWith(s.user.id+'/')&&!f.path.includes('..')).map(f=>f.path);if(!paths.length)continue;
  const current=await identity();if(current.user.id!==s.user.id)throw Error('Account changed.');
  const result=await A.request('/storage/v1/object/'+bucket,{prefixes:paths},current,'DELETE');removed+=Array.isArray(result)?result.length:0;
 }return removed;
}
async function backups(){return A.request('/rest/v1/cb_workspace_backups?select=workspace,revision,created_at&workspace=eq.'+encodeURIComponent(window.CoBridesCloud.workspace)+'&order=revision.desc&limit=20',null,await identity());}
async function restore(rev){const cloud=window.CoBridesCloud,state=cloud.status();if(state.pending||['conflict','saving','error','offline'].includes(state.state))throw Error('Save or download your current changes before restoring a version.');
 const result=await A.request('/rest/v1/rpc/cb_restore_workspace',{p_workspace:cloud.workspace,p_backup_revision:rev,p_revision:state.revision},await identity());
 // Remove only this account's hydrated cache; the server remains the source of truth.
 localStorage.removeItem(cloud.cacheKey);location.reload();return result;
}
function button(label,action){const b=document.createElement('button');b.type='button';b.textContent=label;b.style.cssText='padding:10px 16px;border:0;border-radius:12px;background:linear-gradient(110deg,#bb006d,#ef551d);color:white;font:600 13px system-ui;cursor:pointer';b.onclick=action;return b;}
async function open(){if(dialog?.open)return;dialog=document.createElement('dialog');dialog.style.cssText='width:min(540px,calc(100vw - 40px));max-height:80vh;box-sizing:border-box;border:1px solid #eadce8;border-radius:22px;padding:24px;color:black;font:14px system-ui';
 const title=document.createElement('h2');title.textContent='Storage & recovery';const status=document.createElement('p'),list=document.createElement('div');status.setAttribute('role','status');status.textContent='Loading your saved versions…';
 const close=button('Close',()=>dialog.close());dialog.append(title,status,list,close);document.body.append(dialog);dialog.addEventListener('close',()=>dialog.remove(),{once:true});dialog.showModal();
 try{const [stats,rows]=await Promise.all([usage(),backups()]);if(!dialog.open)return;status.textContent=(stats.used/1048576).toFixed(1)+' MB of '+(stats.limit/1048576)+' MB used. Recovery keeps up to 20 versions for up to 30 days.';
  if(!rows.length){const empty=document.createElement('p');empty.textContent='Recovery versions appear as you save changes.';list.append(empty);}
  for(const row of rows){const line=document.createElement('div');line.style.cssText='display:flex;align-items:center;justify-content:space-between;gap:12px;margin:12px 0';const label=document.createElement('span');label.textContent=new Date(row.created_at).toLocaleString()+' · Version '+row.revision;const action=button('Restore',async()=>{if(!confirm('Restore this saved version? Your current saved version will also be kept for recovery.'))return;action.disabled=true;try{await restore(row.revision);}catch(e){status.textContent=e.message;action.disabled=false;}});line.append(label,action);list.append(line);}
  const clean=button('Clean unused files',async()=>{clean.disabled=true;try{const count=await cleanup();status.textContent=count+' unused files removed. Current files and recovery files are protected.';}catch(e){status.textContent='Cleanup could not finish. '+e.message;}finally{clean.disabled=false;}});list.append(clean);
 }catch(e){status.textContent='Storage & recovery could not load. '+e.message;}
}
async function mount(){if(mounted||!window.CoBridesCloud?.workspace)return;const epoch=generation;try{await usage();if(epoch!==generation||!A.read?.())return;mounted=true;
 // Opportunistic maintenance once per signed-in page, in batches of at most 50.
 void cleanup().catch(()=>{});
 }catch{/* Existing accounts keep loading while the migration is being activated. */}}
function reset(){generation++;mounted=false;dialog?.remove();dialog=null;}
document.addEventListener('click',event=>{if(event.target.closest('[data-open-storage-recovery]'))void open();});
window.CoBridesRecovery={usage,cleanup,backups,restore,open,mount,reset};
})();
