/* Install support; account data and API responses are never cached here. */
(()=>{'use strict';
 if(!('serviceWorker' in navigator)||!window.isSecureContext)return;
 window.addEventListener('load',async()=>{
  try{
   // Preserve an existing explicitly prepared offline installation.
   if(!await navigator.serviceWorker.getRegistration('/'))await navigator.serviceWorker.register('/app-worker.js',{scope:'/'});
  }catch{/* Installation is optional; a registration failure must never block login. */}
 });
})();
