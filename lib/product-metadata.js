'use strict';
function productMetadata(html,pageUrl){
 const image=value=>{if(Array.isArray(value))return value.map(image).find(Boolean)||'';if(value&&typeof value==='object')return image(value.contentUrl||value.url||value.image);if(typeof value!=='string'||!value.trim())return '';try{const url=new URL(value,pageUrl);if(url.protocol!=='https:'||url.username||url.password||!url.hostname.includes('.')||/^(?:\d+\.){3}\d+$/.test(url.hostname)||url.hostname.includes(':')||/(^|\.)(localhost|local|internal|invalid|test)$/.test(url.hostname))return '';return url.href;}catch{return '';}};
 const candidates=[];let visited=0;
 function walk(value,depth=0){if(!value||depth>12||++visited>6000)return;if(Array.isArray(value)){value.forEach(v=>walk(v,depth+1));return;}if(typeof value!=='object')return;const types=[value['@type']].flat();if(types.some(type=>/(^|[/#])(Product|ProductGroup)$/.test(String(type))))candidates.push(value);for(const key of ['@graph','mainEntity','itemListElement','item','hasVariant'])if(value[key])walk(value[key],depth+1);}
 for(const match of html.matchAll(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script\s*>/gi)){if(match[1].length>600000)continue;try{walk(JSON.parse(match[1]));}catch{}}
 const product=candidates.find(p=>{try{return new URL(p.url||p['@id'],pageUrl).pathname===new URL(pageUrl).pathname&&image(p.image);}catch{return false;}})||candidates.find(p=>image(p.image))||candidates[0];
 let photo=image(product?.image),name=typeof product?.name==='string'?product.name.slice(0,120):'';
 if(!photo){for(const tag of html.match(/<(?:img|meta)\b[^>]{0,12000}>/gi)||[]){const attrs={};for(const m of tag.matchAll(/([a-z_:][a-z0-9_:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi))attrs[m[1].toLowerCase()]=m[2]??m[3]??m[4];if(attrs.itemprop==='image'||['landingImage','imgBlkFront','main-product-image','product-image'].includes(attrs.id)){photo=image((attrs.content||attrs['data-old-hires']||attrs['data-src']||attrs.src||'').replace(/&amp;/g,'&'));if(photo)break;}}}
 return {image:photo,title:name};
}
module.exports={productMetadata};
