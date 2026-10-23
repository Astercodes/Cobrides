/* IndexedDB avoids the small synchronous localStorage quota for workspace caches/outboxes. */
(()=>{'use strict';let connection;
function database(){if(!connection)connection=new Promise((resolve,reject)=>{const request=indexedDB.open('cobrides-workspaces',1);request.onupgradeneeded=()=>request.result.createObjectStore('values');request.onsuccess=()=>{request.result.onversionchange=()=>{request.result.close();connection=null;};resolve(request.result);};request.onerror=()=>{connection=null;reject(request.error);};});return connection;}
async function transaction(mode,fn){const db=await database();return new Promise((resolve,reject)=>{const tx=db.transaction('values',mode),store=tx.objectStore('values');let value;tx.oncomplete=()=>resolve(value);tx.onerror=()=>reject(tx.error||Error('Device storage unavailable'));tx.onabort=()=>reject(tx.error||Error('Device storage unavailable'));const request=fn(store);if(request)request.onsuccess=()=>{value=request.result;};});}
window.CoBridesDeviceStore={get:key=>transaction('readonly',s=>s.get(key)),put:(key,value)=>transaction('readwrite',s=>s.put(value,key)),remove:key=>transaction('readwrite',s=>s.delete(key))};
})();
