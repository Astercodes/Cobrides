'use strict';
const crypto=require('node:crypto');
const {publicKey}=require('./workspace-config');
const events=new Set(['email.delivered','email.bounced','email.complained','email.failed','email.delivery_delayed','email.suppressed']);
function verified(raw,headers,secret,now=Date.now()){
 if(!/^whsec_[A-Za-z0-9+/=_-]+$/.test(secret||''))return false;
 const id=headers['svix-id'],timestamp=headers['svix-timestamp'],signature=headers['svix-signature'];
 if(typeof id!=='string'||!/^[A-Za-z0-9_-]{1,200}$/.test(id)||typeof timestamp!=='string'||!/^\d{10}$/.test(timestamp)||Math.abs(now/1000-Number(timestamp))>300||typeof signature!=='string'||signature.length>4096)return false;
 const key=Buffer.from(secret.slice(6),'base64');if(key.length<16||key.length>128)return false;
 const expected=crypto.createHmac('sha256',key).update(id+'.'+timestamp+'.'+raw).digest();
 return signature.split(/\s+/).some(part=>{const [version,value]=part.split(',');if(version!=='v1'||!/^[A-Za-z0-9+/=_-]+$/.test(value||''))return false;const actual=Buffer.from(value,'base64');return actual.length===expected.length&&crypto.timingSafeEqual(actual,expected);});
}
function createHandler({env=process.env,fetcher=fetch,now=Date.now}={}){
 return async(req,res)=>{
  res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');
  const reply=(status,value)=>{res.statusCode=status;res.end(JSON.stringify(value));};
  if(req.method!=='POST'){res.setHeader('Allow','POST');return reply(405,{error:'Use POST.'});}
  const secret=env.RESEND_WEBHOOK_SECRET||'',url=(env.SUPABASE_URL||'').trim().replace(/\/+$/,''),key=(env.SUPABASE_PUBLISHABLE_KEY||'').trim();
  if(!secret||!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)||!publicKey(key))return reply(503,{error:'Delivery updates are not configured.'});
  try{
   const chunks=[];let size=0;for await(const chunk of req){const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);size+=bytes.length;if(size>262144)return reply(413,{error:'Request too large.'});chunks.push(bytes);}
   const raw=Buffer.concat(chunks).toString('utf8');
   if(!verified(raw,req.headers,secret,now()))return reply(401,{error:'Invalid webhook signature.'});
   let event;try{event=JSON.parse(raw);}catch{return reply(400,{error:'Invalid event.'});}
   if(!events.has(event?.type))return reply(200,{ignored:true});
   const date=Date.parse(event.created_at);
   if(typeof event.data?.email_id!=='string'||!/^[A-Za-z0-9_-]{1,160}$/.test(event.data.email_id)||!Number.isFinite(date)||date>now()+300000||date<Date.UTC(2000,0,1))return reply(400,{error:'Invalid delivery event.'});
   const result=await fetcher(url+'/rest/v1/rpc/cb_record_planning_delivery',{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({p_secret:secret,p_event_id:req.headers['svix-id'],p_email_id:event.data.email_id,p_kind:event.type,p_occurred:new Date(date).toISOString()}),signal:AbortSignal.timeout(10000)});
   if(!result.ok)return reply(503,{error:'Delivery update could not be saved. Please retry.'});
   return reply(200,{received:true});
  }catch{return reply(503,{error:'Delivery update could not be saved. Please retry.'});}
 };
}
module.exports=createHandler();module.exports.createHandler=createHandler;module.exports.verified=verified;
module.exports.config={api:{bodyParser:false}};
