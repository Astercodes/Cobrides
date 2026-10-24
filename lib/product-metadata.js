'use strict';
function productMetadata(html,pageUrl){
 const image=value=>{if(Array.isArray(value))return value.map(image).find(Boolean)||'';if(value&&typeof value==='object')return image(value.contentUrl||value.url||value.image);if(typeof value!=='string'||!value.trim())return '';try{const url=new URL(value,pageUrl);if(url.protocol!=='https:'||url.username||url.password||!url.hostname.includes('.')||/^(?:\d+\.){3}\d+$/.test(url.hostname)||url.hostname.includes(':')||/(^|\.)(localhost|local|internal|invalid|test)$/.test(url.hostname))return '';return url.href;}catch{return '';}};
 const candidates=[];let visited=0;
 function walk(value,depth=0){if(!value||depth>12||++visited>6000)return;if(Array.isArray(value)){value.forEach(v=>walk(v,depth+1));return;}if(typeof value!=='object')return;const types=[value['@type']].flat();if(types.some(type=>/(^|[/#])(Product|ProductGroup)$/.test(String(type))))candidates.push(value);for(const key of ['@graph','mainEntity','itemListElement','item','hasVariant'])if(value[key])walk(value[key],depth+1);}
 for(const match of html.matchAll(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script\s*>/gi)){if(match[1].length>600000)continue;try{walk(JSON.parse(match[1]));}catch{}}
 const product=candidates.find(p=>{try{return new URL(p.url||p['@id'],pageUrl).pathname===new URL(pageUrl).pathname&&image(p.image);}catch{return false;}})||candidates.find(p=>image(p.image))||candidates[0];
 let photo=image(product?.image),name=typeof product?.name==='string'?product.name.slice(0,120):'';
 const decode=value=>String(value||'').replace(/&quot;|&#34;/g,'"').replace(/&#39;|&apos;/g,"'").replace(/&amp;/g,'&');
 if(!photo){for(const tag of html.match(/<(?:img|meta)\b[^>]{0,40000}>/gi)||[]){const attrs={};for(const m of tag.matchAll(/([a-z_:][a-z0-9_:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi))attrs[m[1].toLowerCase()]=m[2]??m[3]??m[4];if(attrs.itemprop==='image'||['landingImage','imgBlkFront','main-product-image','product-image'].includes(attrs.id)){
  photo=image(decode(attrs.content||attrs['data-old-hires']||''));
  if(!photo&&attrs['data-a-dynamic-image']){try{const sizes=JSON.parse(decode(attrs['data-a-dynamic-image']));photo=Object.entries(sizes).filter(([url])=>image(url)).sort((a,b)=>((+b[1]?.[0]||0)*(+b[1]?.[1]||0))-((+a[1]?.[0]||0)*(+a[1]?.[1]||0))).map(([url])=>image(url))[0]||'';}catch{}}
  photo=photo||image(decode(attrs['data-src']||attrs.src||''));if(photo)break;
 }}}
 // Amazon's main gallery can be embedded in JavaScript instead of schema markup.
 if(!photo&&/(^|\.)amazon\.(com|co\.uk|ca|de|fr|it|es|in|com\.au|co\.jp|com\.br|com\.mx|ae|sa|nl|se|pl|sg|com\.be|com\.tr|ie|eg|co\.za)$/.test(new URL(pageUrl).hostname)){
  const gallery=html.match(/["']colorImages["']\s*:\s*\{\s*["']initial["']\s*:\s*\[([\s\S]{0,200000}?)(?:\]\s*[,}])/i)?.[1];
  if(gallery){const first=gallery.match(/\{[\s\S]*?\}/)?.[0]||gallery;for(const key of ['hiRes','large']){const value=first.match(new RegExp('["\']'+key+'["\']\\s*:\\s*("(?:\\\\.|[^"\\\\])*")'))?.[1];if(value){try{photo=image(JSON.parse(value));}catch{}if(photo)break;}}}
 }
 const offers=[product?.offers].flat().filter(Boolean),offer=offers.find(o=>o['@type']!=='AggregateOffer'&&o.price!==undefined)||{};
 const raw=offer.price??offer.priceSpecification?.price,currency=String(offer.priceCurrency||offer.priceSpecification?.priceCurrency||'').toUpperCase();
 const amount=typeof raw==='number'?raw:typeof raw==='string'&&/^\d+(?:\.\d{1,4})?$/.test(raw.trim())?Number(raw):NaN;
 return {image:photo,title:name,...(Number.isFinite(amount)&&amount>=0&&/^[A-Z]{3}$/.test(currency)?{price:amount,currency}:{})};
}
module.exports={productMetadata};
