'use strict';
const {amazonItem}=require('./amazon-products');
const {productMetadata}=require('./product-metadata');
async function retrievePublicProductPage(url){
 // This is a fixed public host and ASIN-only path, never an arbitrary user URL.
 if(!/^https:\/\/bigbangprice\.com\/product\/[A-Z0-9]{10}\/$/.test(url))throw Error('Invalid source');
 const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(12000),headers:{'User-Agent':'CobrideyLinkPreview/1.0 (+https://www.cobridey.com)',Accept:'text/html'}});
 if(!response.ok||!/^text\/html/i.test(response.headers.get('content-type')||''))throw Error('Unavailable source');
 const reader=response.body.getReader(),parts=[];let size=0;
 try{for(;;){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>1024*1024)throw Error('Source too large');parts.push(Buffer.from(value));}}finally{await reader.cancel().catch(()=>{});}
 return {url,html:Buffer.concat(parts).toString('utf8')};
}
function createPublicLookup({retrievePage=retrievePublicProductPage,now=Date.now}={}){
 const cache=new Map(),pending=new Map();
 return async function lookup(value){
  const item=amazonItem(value);if(!item||item.domain!=='amazon.com')return null;
  const key=item.domain+':'+item.asin,cached=cache.get(key);
  if(cached?.expires>now())return cached.data?{...cached.data,url:value}:null;
  if(pending.has(key)){const data=await pending.get(key);return data?{...data,url:value}:null;}
  const job=Promise.resolve().then(async()=>{
   let data=null;
   try{
    const source='https://bigbangprice.com/product/'+item.asin+'/',page=await retrievePage(source,{fullPage:true});
    // Require both the exact canonical product and its ASIN in the page title.
    // Generic search results, redirects and unrelated recommendations cannot qualify.
    if(page.url!==source)return null;
    const canonical=(page.html.match(/<link\b[^>]*>/gi)||[]).some(tag=>/\brel\s*=\s*["']canonical["']/i.test(tag)&&tag.match(/\bhref\s*=\s*["']([^"']+)["']/i)?.[1]===source);
    const title=page.html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]||'';
    if(!canonical||!new RegExp('\\b'+item.asin+'\\b','i').test(title))return null;
    const product=productMetadata(page.html,source);if(!product.image||!product.title)return null;
    const image=new URL(product.image);
    if(image.protocol!=='https:'||image.username||image.password||!/(^|\.)(media-amazon\.com|images-amazon\.com|images\.amazon\.com)$/.test(image.hostname))return null;
    data={title:product.title,image:image.href,description:'',creator:'Amazon',provider:item.domain,...(product.price!==undefined?{price:product.price,currency:product.currency}:{}),priceSource:source,priceCheckedAt:new Date(now()).toISOString()};
    return data;
   }catch{return null;}
   finally{cache.set(key,{data,expires:now()+(data?3600000:60000)});if(cache.size>200)cache.delete(cache.keys().next().value);pending.delete(key);}
  });
  pending.set(key,job);const data=await job;return data?{...data,url:value}:null;
 };
}
module.exports={createPublicLookup,retrievePublicProductPage};
