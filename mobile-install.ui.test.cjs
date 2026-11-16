'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium}=require(process.env.CB_PLAYWRIGHT_PATH);
(async()=>{
 const root=path.join(__dirname,'dist'),types={'.html':'text/html','.js':'text/javascript','.css':'text/css','.webmanifest':'application/manifest+json','.png':'image/png','.svg':'image/svg+xml','.json':'application/json','.webp':'image/webp'};
 const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://localhost'),file=path.resolve(root,'.'+(url.pathname==='/'?'/index.html':url.pathname));
  if(!file.startsWith(root+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile()){res.writeHead(404);return res.end();}
  res.setHeader('Content-Type',types[path.extname(file)]||'application/octet-stream');res.end(fs.readFileSync(file));
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
 try{
  browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
  const context=await browser.newContext({viewport:{width:390,height:844}}),page=await context.newPage();
  const origin='http://127.0.0.1:'+server.address().port;
  await page.goto(origin+'/login.html');
  await page.waitForFunction(()=>!!navigator.serviceWorker.controller,{timeout:15000});
  assert.equal(await page.locator('link[rel=manifest]').getAttribute('href'),'/manifest.webmanifest');
  const response=await context.request.get(origin+'/manifest.webmanifest');assert.equal(response.status(),200);
  assert.equal((await response.json()).start_url,'/journey.html#home');
  const cached=await page.evaluate(async()=>{const c=await caches.open('cobridey-install-v1');return (await c.keys()).map(r=>new URL(r.url).pathname);});
  assert.deepEqual(cached,['/app-offline.html']);
  await context.setOffline(true);await page.goto(origin+'/journey.html');
  assert.match(await page.locator('h1').innerText(),/A little pause/);
  assert.equal(await page.locator('button').innerText(),'Try again');
  await context.setOffline(false);await page.goto(origin+'/login.html');
  assert.equal(await page.locator('[data-auth-mode="login"]').count(),1);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),false);
  console.log('Real service-worker installation, offline launch, reconnect and mobile login layout passed.');
 }finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
