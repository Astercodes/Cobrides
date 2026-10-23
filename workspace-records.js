/* Paginated record reads and staged, atomic record changes; owner JWT only. */
(()=>{'use strict';const A=window.CoBridesAuth,C=window.CoBridesRecordCore;let baseline=new Map(),normalized=false,account='',space='',attempt;
async function load(head,session,workspace){account=session.user.id;space=workspace;baseline=new Map();normalized=head?.payload?.cbRecordStore===1;attempt=null;if(!normalized)return head?.payload||null;
 const rev=head.revision,rows=new Map();let offset=0;while(true){const page=await A.request('/rest/v1/cb_workspace_records?select=record_key,body&user_id=eq.'+encodeURIComponent(account)+'&workspace=eq.'+encodeURIComponent(space)+'&from_revision=lte.'+rev+'&or=(to_revision.is.null,to_revision.gt.'+rev+')&order=record_key.asc&limit=250&offset='+offset,null,session);for(const row of page)rows.set(row.record_key,row.body);if(page.length<250)break;offset+=page.length;}
 if(!rows.size)throw Error('Your workspace records could not load. Please retry.');baseline=rows;return C.decode(rows);
}
async function commit(payload,revision,session){if(session.user.id!==account)throw Error('Account changed before saving.');const next=C.encode(payload),changes=C.diff(baseline,next);if(!changes.length&&normalized)return revision;const pages=C.batches(changes),fingerprint=[...next].map(([key,body])=>[key,body]);
 const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(C.stringify(fingerprint.sort(([a],[b])=>a.localeCompare(b))))))].map(x=>x.toString(16).padStart(2,'0')).join('');
 const deviceKey='cb-record-attempt:'+account+':'+space;let saved;try{saved=await window.CoBridesDeviceStore?.get(deviceKey);}catch{}
 if(!attempt||attempt.revision!==revision||attempt.hash!==hash)attempt=saved?.revision===revision&&saved.hash===hash?saved:{id:crypto.randomUUID(),revision,hash};
 // Persist the retry token before staging. If unavailable, the durable outbox still retains edits.
 try{await window.CoBridesDeviceStore?.put(deviceKey,attempt);}catch{}
 await A.request('/rest/v1/rpc/cb_begin_record_save',{p_workspace:space,p_batch:attempt.id,p_revision:revision,p_count:changes.length,p_fingerprint:hash,p_replace:!normalized},session);
 for(const page of pages)await A.request('/rest/v1/rpc/cb_stage_record_save',{p_batch:attempt.id,p_changes:page},session);
 const result=await A.request('/rest/v1/rpc/cb_commit_record_save',{p_batch:attempt.id},session);
 baseline=next;normalized=true;attempt=null;try{await window.CoBridesDeviceStore?.remove(deviceKey);}catch{}return result;
}
function reset(){baseline=new Map();normalized=false;account='';space='';attempt=null;}
window.CoBridesRecords={load,commit,reset};
})();
