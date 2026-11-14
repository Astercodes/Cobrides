const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.CB_PLAYWRIGHT_PATH);
(async()=>{
 const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
 try{
  const page=await browser.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://public.test/**',route=>{
   const url=new URL(route.request().url());
   if(url.pathname.startsWith('/api/'))return route.fulfill({json:{}});
   const file=path.join(process.cwd(),url.pathname==='/'?'index.html':url.pathname);
   if(!fs.existsSync(file))return route.abort();
   return route.fulfill({body:fs.readFileSync(file),contentType:{'.html':'text/html','.css':'text/css','.js':'text/javascript','.webp':'image/webp','.svg':'image/svg+xml','.ttf':'font/ttf'}[path.extname(file)]||'application/octet-stream'});
  });
  for(const width of [1440,390])for(const file of ['index.html','features.html','pricing.html','welcome.html','help.html','privacy.html']){
   await page.setViewportSize({width,height:1000});await page.goto('https://public.test/'+file);await page.waitForTimeout(1000);
   const footer=page.locator('footer.launch-footer');assert.equal(await footer.count(),1,file+' has the shared footer');const links=await footer.locator('a').evaluateAll(as=>as.map(a=>a.getAttribute('href')));assert.deepEqual(links,['index.html','features.html','pricing.html','welcome.html','help.html','privacy.html','signup.html','login.html']);for(const href of links)assert(fs.existsSync(href),'Footer target exists: '+href);if(file==='index.html'){
    const product=await page.locator('img[src^="assets/product/"]').evaluateAll(imgs=>imgs.map(i=>i.getAttribute('src')));
    assert.equal(product.length,2);assert.equal(new Set(product).size,2,'Product views must not repeat');
    assert.equal(await page.locator('img[src^="assets/editorial/"]').count(),9);
    for(const section of ['.hero','#documents','.vision-section','#celebrations','#wedding-experience','#people','#next','#personal-preparation','#your-way','.pricing-teaser','.final-cta'])assert.equal(await page.locator(section+' a.cta,'+section+' a.text-link').count(),1,section+' should have one action');
    assert.equal(await page.locator('.launch-hero-art img').count(),1);
   }
   if(file==='features.html'){
    assert.equal(await page.locator('.features-hero .actions a').count(),1);
    await page.locator('#pricing-feature-search').fill('Documents');
    assert.equal(await page.locator('#category-documents').isVisible(),true);
    await page.locator('#pricing-feature-search').fill('');
   }
   if(file==='pricing.html')assert.equal(await page.locator('.pricing-hero .actions a').count(),1);
   if(file==='welcome.html')for(const selector of ['.pro-intro .pro-actions a','.pro-connection .pro-actions a'])assert.equal(await page.locator(selector).count(),1);
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,file+' overflow '+width);
   if(width===390){await page.locator('.public-menu-toggle').click();assert.equal(await page.locator('.public-menu-toggle').getAttribute('aria-expanded'),'true');await page.keyboard.press('Escape');}
   await page.evaluate(async()=>{for(let y=0;y<document.body.scrollHeight;y+=650){scrollTo({top:y,behavior:'instant'});await new Promise(r=>setTimeout(r,45));}scrollTo({top:0,behavior:'instant'});});
   await page.waitForTimeout(900);
   const broken=await page.locator('img').evaluateAll(imgs=>imgs.filter(i=>!i.complete||!i.naturalWidth).map(i=>i.src));assert.deepEqual(broken,[],file);
   await page.screenshot({path:'C:/Users/ayeni/Downloads/launch-'+file+'-'+width+'.png',fullPage:true});console.log(file,width);
  }
  assert.deepEqual(errors,[]);console.log('Public launch checks passed: single actions, expanded scope, Documents search, mobile layout and artwork.');
 }finally{await browser.close();}
})();
