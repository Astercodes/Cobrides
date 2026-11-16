'use strict';
// Rasterize Cobridey's existing vector logo; no new logo or generated artwork.
const fs=require('node:fs'),path=require('node:path');
const {chromium}=require(process.env.CB_PLAYWRIGHT_PATH||'playwright');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CB_CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
 try{
  const page=await browser.newPage({deviceScaleFactor:1}),root=path.join(__dirname,'..');
  const svg=fs.readFileSync(path.join(root,'assets/logo.svg'),'utf8');
  const web=path.join(root,'assets/app');fs.mkdirSync(web,{recursive:true});
  async function draw(size,destination){
   await page.setViewportSize({width:size,height:size});
   await page.setContent('<style>html,body{margin:0;width:100%;height:100%;background:#fff9f4}body{display:grid;place-items:center}svg{width:62%;height:62%;display:block}</style>'+svg);
   await page.screenshot({path:destination});
  }
  for(const size of [180,192,512])await draw(size,path.join(web,`icon-${size}.png`));
  await draw(512,path.join(web,'icon-maskable-512.png'));
  for(const [density,size] of [['mdpi',48],['hdpi',72],['xhdpi',96],['xxhdpi',144],['xxxhdpi',192]]){
   const folder=path.join(__dirname,'android/app/src/main/res','mipmap-'+density);fs.mkdirSync(folder,{recursive:true});
   await draw(size,path.join(folder,'ic_launcher.png'));
  }
  console.log('Web and Android icons created from the existing Cobridey logo.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
