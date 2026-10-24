'use strict';
const marketplaces=new Set(['amazon.com','amazon.co.uk','amazon.ca','amazon.de','amazon.fr','amazon.it','amazon.es','amazon.in','amazon.com.au','amazon.co.jp','amazon.com.br','amazon.com.mx','amazon.ae','amazon.sa','amazon.nl','amazon.se','amazon.pl','amazon.sg','amazon.com.be','amazon.com.tr','amazon.ie','amazon.eg','amazon.co.za']);
function amazonItem(value){try{const u=new URL(value),domain=u.hostname.replace(/^(www|smile|m)\./,'');if(u.protocol!=='https:'||u.username||u.password||!marketplaces.has(domain))return null;const asin=u.pathname.match(/\/(?:dp|gp\/product|gp\/aw\/d)\/([a-z0-9]{10})(?:[/?]|$)/i)?.[1]?.toUpperCase();return asin?{asin,domain}:null;}catch{return null;}}
function amazonChallenge(html){return /\/errors_page\/validateCaptcha|<title[^>]*>\s*Robot Check\s*<\/title>|automated access to Amazon data/i.test(html);}
function createLookup({env=process.env,fetcher=fetch,now=Date.now}={}){
 const cache=new Map(),pending=new Map();
 return async function lookup(value){const item=amazonItem(value);if(!item||!env.RAINFOREST_API_KEY)return null;const key=item.domain+':'+item.asin,cached=cache.get(key);if(cached?.expires>now())return {...cached.data,url:value};if(pending.has(key))return {...await pending.get(key),url:value};
 const job=Promise.resolve().then(async()=>{try{
  const url=new URL('https://api.rainforestapi.com/request');url.search=new URLSearchParams({api_key:env.RAINFOREST_API_KEY,type:'product',amazon_domain:item.domain,asin:item.asin}).toString();
  const response=await fetcher(url,{headers:{Accept:'application/json'},signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('Provider unavailable');const result=await response.json(),p=result.product;
  if(result.request_info?.success!==true||String(p?.asin).toUpperCase()!==item.asin||typeof p?.main_image?.link!=='string')throw Error('Product not returned');const image=new URL(p.main_image.link);
  if(image.protocol!=='https:'||image.username||image.password||!/(^|\.)(media-amazon\.com|images-amazon\.com|images\.amazon\.com)$/.test(image.hostname))throw Error('Invalid product image');
  const data={title:String(p.title||'Amazon product').slice(0,120),image:image.href,description:typeof p.description==='string'?p.description.slice(0,800):'',creator:'Amazon',provider:item.domain};cache.set(key,{data,expires:now()+3600000});if(cache.size>200)cache.delete(cache.keys().next().value);return data;
 }catch{throw Object.assign(Error('Amazon product details are temporarily unavailable. Your product link can still be saved.'),{status:422,reason:'amazon_product_unavailable'});}finally{pending.delete(key);}});pending.set(key,job);return {...await job,url:value};
 };
}
module.exports={amazonItem,amazonChallenge,createLookup,lookup:createLookup()};
