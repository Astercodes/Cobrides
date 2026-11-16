/* Network first, no account, page, file or API response caching. */
const CACHE='cobridey-install-v1';
self.addEventListener('install',event=>event.waitUntil((async()=>{
 const cache=await caches.open(CACHE);await cache.add('/app-offline.html');await self.skipWaiting();
})()));
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('fetch',event=>{
 const url=new URL(event.request.url);
 if(event.request.method!=='GET'||event.request.mode!=='navigate'||url.origin!==self.location.origin||url.pathname.startsWith('/api/'))return;
 event.respondWith(fetch(event.request).catch(async()=>{
  const cache=await caches.open(CACHE);return await cache.match('/app-offline.html')||Response.error();
 }));
});
