'use strict';
// Vercel Node function. No provider credentials are ever returned to the browser.
const crypto = require('node:crypto');
const CALENDAR = 'https://www.googleapis.com/auth/calendar.events.readonly';
const MAIL = 'https://www.googleapis.com/auth/gmail.send';
const TTL = 30 * 86400;
const random = () => crypto.randomBytes(32).toString('base64url');
const failure = (status, message) => Object.assign(new Error(message), {status});
function seal(value, secret) {
  const iv = crypto.randomBytes(12), cipher = crypto.createCipheriv('aes-256-gcm', crypto.createHash('sha256').update(secret).digest(), iv);
  const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), data]).toString('base64url');
}
function unseal(value, secret) {
  const b = Buffer.from(value, 'base64url'), decipher = crypto.createDecipheriv('aes-256-gcm', crypto.createHash('sha256').update(secret).digest(), b.subarray(0,12));
  decipher.setAuthTag(b.subarray(12,28));
  return JSON.parse(Buffer.concat([decipher.update(b.subarray(28)), decipher.final()]).toString());
}
function configuration(env) {
  const storage = !!(env.UPSTASH_REDIS_REST_URL && env.UPSTASH_REDIS_REST_TOKEN && env.INTEGRATION_ENCRYPTION_KEY?.length >= 32 && env.APP_ORIGIN);
  return {discovery:true, venues:!!(storage && env.GOOGLE_PLACES_API_KEY), storage,
    google:!!(storage && env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET),
    checkout:!!(storage && env.STRIPE_SECRET_KEY && env.STRIPE_REGISTRY_PRICE_ID)};
}
function createHandler({env=process.env, fetcher=fetch, store:injectedStore}={}) {
  const config=configuration(env);
  async function command(...args) {
    if(injectedStore)return injectedStore(...args);
    const r=await fetcher(env.UPSTASH_REDIS_REST_URL,{method:'POST',headers:{Authorization:'Bearer '+env.UPSTASH_REDIS_REST_TOKEN,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(12000)});
    if(!r.ok)throw failure(503,'Connection storage is unavailable.');
    const data=await r.json();if(data.error)throw failure(503,'Connection storage is unavailable.');return data.result;
  }
  const key=(name)=>'cobrides:integrations:'+name;
  const get=async name=>{const v=await command('GET',key(name));return v?unseal(v,env.INTEGRATION_ENCRYPTION_KEY):null;};
  const put=(name,value,ttl=TTL)=>command('SET',key(name),seal(value,env.INTEGRATION_ENCRYPTION_KEY),'EX',ttl);
  const del=name=>command('DEL',key(name));
  async function provider(url, options={}) {
    const r=await fetcher(url,{...options,signal:AbortSignal.timeout(15000)});
    if(!r.ok)throw failure(r.status===401?401:502,r.status===401?'Provider access expired. Reconnect your account.':'The provider could not complete this request. Please retry later.');
    return r.json();
  }
  async function access(session, scope) {
    const account=await get('account:'+session.sub);if(!account)throw failure(401,'Connect your Google account first.');
    if(scope&&!account.scopes.includes(scope))throw failure(403,'Authorize this capability with Google first.');
    if(account.expires < Date.now()+60000) {
      if(!account.refresh)throw failure(401,'Reconnect Google to renew access.');
      const token=await provider('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:account.refresh,client_id:env.GOOGLE_CLIENT_ID,client_secret:env.GOOGLE_CLIENT_SECRET})});
      account.access=token.access_token;account.expires=Date.now()+token.expires_in*1000;await put('account:'+session.sub,account);
    }
    return account;
  }
  return async function handler(req,res) {
    res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
    const json=(status,data)=>{res.statusCode=status;res.setHeader('Content-Type','application/json');res.end(JSON.stringify(data));};
    const redirect=url=>{res.statusCode=303;res.setHeader('Location',url);res.end();};
    try {
      const url=new URL(req.url,'https://cobrides.invalid'), action=url.searchParams.get('action')||'status';
      if(!['GET','POST'].includes(req.method))throw failure(405,'Method not supported.');
      if(action==='stripe-webhook') {
        if(req.method!=='POST')throw failure(405,'Use POST for webhooks.');
        if(!config.storage||!env.STRIPE_WEBHOOK_SECRET)throw failure(503,'Webhook storage and signing secret are not configured.');
        let raw='';for await(const part of req){raw+=part;if(raw.length>200000)throw failure(413,'Webhook too large.');}
        const signature=String(req.headers['stripe-signature']||''),timestamp=signature.match(/(?:^|,)t=(\d+)/)?.[1];
        const expected=crypto.createHmac('sha256',env.STRIPE_WEBHOOK_SECRET).update(timestamp+'.'+raw).digest();
        const valid=timestamp&&Math.abs(Date.now()/1000-Number(timestamp))<300&&[...signature.matchAll(/(?:^|,)v1=([a-f0-9]{64})/g)].some(m=>crypto.timingSafeEqual(expected,Buffer.from(m[1],'hex')));
        if(!valid)throw failure(400,'Invalid webhook signature.');
        const event=JSON.parse(raw);
        if(['checkout.session.completed','checkout.session.async_payment_succeeded','checkout.session.async_payment_failed'].includes(event.type)) {
          const data=event.data?.object;if(!data?.id||!data.metadata?.owner)throw failure(400,'Missing checkout ownership.');
          await put('stripe-event:'+event.id,{id:data.id,owner:data.metadata.owner,status:data.payment_status,type:event.type,at:event.created});
        }
        return json(200,{received:true});
      }
      const mutating=['connect','disconnect','sync','send','checkout'].includes(action);
      if(mutating&&req.method!=='POST')throw failure(405,'Use POST for this action.');
      let body={};
      if(req.method==='POST') {
        if(req.headers.origin!==env.APP_ORIGIN)throw failure(403,'Open this action from the CoBrides application.');
        if(!String(req.headers['content-type']||'').startsWith('application/json'))throw failure(415,'Use JSON requests.');
        if(typeof req.body==='object'&&req.body!==null)body=req.body;
        else {let text='';for await(const part of req){text+=part;if(text.length>20000)throw failure(413,'Request too large.');}body=JSON.parse(text||'{}');}
        if(JSON.stringify(body).length>20000)throw failure(413,'Request too large.');
      }
      if(action==='discover') {
        const query=String(url.searchParams.get('q')||'').trim().slice(0,120);
        if(query.length<3)throw failure(400,'Enter at least three characters.');
        if(url.searchParams.get('provider')==='venues') {
          if(!config.venues)throw failure(503,'Venue discovery needs a Google Places API key and connection storage.');
          // Restrict paid discovery to authenticated users; API keys stay on the server.
          const sid=String(req.headers.cookie||'').match(/(?:^|; )cobrides_session=([A-Za-z0-9_-]+)/)?.[1];
          const session=sid?await get('session:'+sid):null;if(!session)throw failure(401,'Sign in with Google before searching venues.');
          const count=await command('INCR',key('places-limit:'+session.sub+':'+Math.floor(Date.now()/3600000)));if(count===1)await command('EXPIRE',key('places-limit:'+session.sub+':'+Math.floor(Date.now()/3600000)),3600);if(count>30)throw failure(429,'Venue search hourly limit reached.');
          const data=await provider('https://places.googleapis.com/v1/places:searchText',{method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':env.GOOGLE_PLACES_API_KEY,'X-Goog-FieldMask':'places.id,places.displayName,places.formattedAddress,places.googleMapsUri'},body:JSON.stringify({textQuery:query,pageSize:10})});
          return json(200,{items:(data.places||[]).map(p=>({id:p.id,title:p.displayName?.text||'Venue',url:p.googleMapsUri,notes:p.formattedAddress||'',type:'Vendor',provider:'Google Places'}))});
        }
        const params=new URLSearchParams({action:'query',format:'json',generator:'search',gsrsearch:query,gsrnamespace:'6',gsrlimit:'12',prop:'imageinfo',iiprop:'url|extmetadata',iiurlwidth:'500'});
        const data=await provider('https://commons.wikimedia.org/w/api.php?'+params,{headers:{'User-Agent':'CoBrides/0.3 (https://furbrides.vercel.app; bridal inspiration discovery)'}});
        const plain=s=>String(s||'').replace(/<[^>]*>/g,'').slice(0,300);
        return json(200,{items:Object.values(data.query?.pages||{}).map(p=>{const i=p.imageinfo?.[0],m=i?.extmetadata;return {id:String(p.pageid),title:p.title.replace(/^File:/,''),url:i?.descriptionurl,image:/^https:\/\/(upload|thumb)\.wikimedia\.org\//.test(i?.thumburl||'')?i.thumburl:'',type:'Inspiration',provider:'Wikimedia Commons',notes:plain(m?.Artist?.value)+' · '+plain(m?.LicenseShortName?.value),licenseUrl:m?.LicenseUrl?.value||''};}).filter(i=>i.url?.startsWith('https://commons.wikimedia.org/'))});
      }
      if(action==='status'&&!config.storage)return json(200,{configured:config,account:null,csrf:null});
      if(!config.storage)throw failure(503,'Configure APP_ORIGIN, encrypted connection storage and provider credentials in Vercel.');
      const sid=String(req.headers.cookie||'').match(/(?:^|; )cobrides_session=([A-Za-z0-9_-]+)/)?.[1];
      let session=sid?await get('session:'+sid):null;
      if(action==='status') {
        const account=session?.sub?await get('account:'+session.sub):null;
        return json(200,{configured:config,csrf:session?.csrf||null,account:account?{email:account.email,calendar:account.scopes.includes(CALENDAR),mail:account.scopes.includes(MAIL)}:null});
      }
      if(action==='connect') {
        if(!config.google)throw failure(503,'Google OAuth credentials have not been configured.');
        const purpose=body.purpose==='mail'?'mail':'calendar', flow=random(), binding=random(), verifier=random();
        await put('oauth:'+flow,{binding,verifier,purpose,sub:session?.sub||null},600);
        res.setHeader('Set-Cookie','cobrides_oauth='+binding+'; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600');
        const params=new URLSearchParams({client_id:env.GOOGLE_CLIENT_ID,redirect_uri:env.APP_ORIGIN+'/api/integrations?action=callback',response_type:'code',scope:'openid email '+(purpose==='mail'?MAIL:CALENDAR),access_type:'offline',prompt:'consent',include_granted_scopes:'true',state:flow,code_challenge:crypto.createHash('sha256').update(verifier).digest('base64url'),code_challenge_method:'S256'});
        return json(200,{url:'https://accounts.google.com/o/oauth2/v2/auth?'+params});
      }
      if(action==='callback') {
        const flow=url.searchParams.get('state'), pending=flow?await get('oauth:'+flow):null;
        const binding=String(req.headers.cookie||'').match(/(?:^|; )cobrides_oauth=([A-Za-z0-9_-]+)/)?.[1];
        if(!pending||!binding||pending.binding!==binding)throw failure(403,'Google connection expired or could not be verified. Start again.');
        // Atomic consumption blocks callback replay across function instances.
        const used=await command('SET',key('oauth-used:'+flow),'1','NX','EX',600);if(!used)throw failure(409,'Connection callback already used.');await del('oauth:'+flow);
        if(url.searchParams.has('error'))return redirect(env.APP_ORIGIN+'/journey.html?connection=declined#imports');
        const token=await provider('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({code:url.searchParams.get('code')||'',client_id:env.GOOGLE_CLIENT_ID,client_secret:env.GOOGLE_CLIENT_SECRET,redirect_uri:env.APP_ORIGIN+'/api/integrations?action=callback',grant_type:'authorization_code',code_verifier:pending.verifier})});
        const user=await provider('https://openidconnect.googleapis.com/v1/userinfo',{headers:{Authorization:'Bearer '+token.access_token}});
        if(!user.sub||!user.email_verified)throw failure(403,'A verified Google account is required.');
        if(pending.sub&&pending.sub!==user.sub)throw failure(409,'Use the same Google account, or disconnect before switching accounts.');
        const old=await get('account:'+user.sub), scopes=String(token.scope||'').split(' ');
        if(!scopes.includes(pending.purpose==='mail'?MAIL:CALENDAR))throw failure(403,'The required permission was not granted.');
        await put('account:'+user.sub,{email:user.email,access:token.access_token,refresh:token.refresh_token||old?.refresh,expires:Date.now()+token.expires_in*1000,scopes});
        if(sid)await del('session:'+sid);
        const newSid=random();session={sub:user.sub,csrf:random()};await put('session:'+newSid,session);
        res.setHeader('Set-Cookie',['cobrides_session='+newSid+'; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age='+TTL,'cobrides_oauth=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0']);
        return redirect(env.APP_ORIGIN+'/journey.html?connection=connected#imports');
      }
      if(!session?.sub)throw failure(401,'Connect your Google account first.');
      if(!await get('account:'+session.sub))throw failure(401,'This account was disconnected. Reconnect Google.');
      if(req.method==='POST'&&req.headers['x-cobrides-csrf']!==session.csrf)throw failure(403,'Refresh your connection status and retry.');
      if(action==='disconnect') {
        const account=await get('account:'+session.sub);
        if(account?.refresh||account?.access)await fetcher('https://oauth2.googleapis.com/revoke',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({token:account.refresh||account.access}),signal:AbortSignal.timeout(12000)}).then(r=>{if(!r.ok)throw failure(502,'Google revocation failed. Retry disconnect.');});
        await del('account:'+session.sub);await del('calendar:'+session.sub);await del('session:'+sid);
        res.setHeader('Set-Cookie','cobrides_session=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0');return json(200,{disconnected:true});
      }
      if(action==='sync') {
        const account=await access(session,CALENDAR), previous=await get('calendar:'+session.sub)||{items:[],token:''};
        let items=new Map(previous.items.map(i=>[i.id,i])), cursor=body.reset?'':previous.token, page='', nextToken='', pages=0;
        if(!cursor)items.clear();
        do {
          const params=new URLSearchParams({maxResults:'250',showDeleted:'true'});if(cursor)params.set('syncToken',cursor);if(page)params.set('pageToken',page);
          const r=await fetcher('https://www.googleapis.com/calendar/v3/calendars/primary/events?'+params,{headers:{Authorization:'Bearer '+account.access},signal:AbortSignal.timeout(15000)});
          if(r.status===410){await del('calendar:'+session.sub);throw failure(409,'Google reset this calendar cursor. Run a full refresh.');}
          if(!r.ok)throw failure(502,'Google Calendar could not be synchronized.');const data=await r.json();
          for(const e of data.items||[])items.set(e.id,{id:e.id,title:e.summary||'Private event',start:e.start||{},end:e.end||{},recurrence:e.recurrence||[],status:e.status,updated:e.updated,url:e.htmlLink||''});
          page=data.nextPageToken||'';nextToken=data.nextSyncToken||'';
          if(items.size>5000||++pages>=20&&page)throw failure(422,'Calendar is too large for this connection. No partial cursor was saved.');
        }while(page);
        const snapshot={items:[...items.values()],token:nextToken,at:new Date().toISOString()};await put('calendar:'+session.sub,snapshot);
        return json(200,{items:snapshot.items,at:snapshot.at});
      }
      if(action==='send') {
        const account=await access(session,MAIL), to=String(body.to||''), subject=String(body.subject||''), message=String(body.message||'');
        if(!/^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/.test(to)||to.length>254||/[\r\n]/.test(subject)||!subject.trim()||subject.length>150||!message.trim()||message.length>5000||body.confirm!==true)throw failure(400,'Review one email recipient, subject and message, then confirm sending.');
        const requestId=String(body.requestId||'');if(!/^[A-Za-z0-9_-]{16,80}$/.test(requestId))throw failure(400,'A unique send request is required.');
        const limitKey=key('mail-limit:'+session.sub+':'+Math.floor(Date.now()/3600000)),count=await command('INCR',limitKey);if(count===1)await command('EXPIRE',limitKey,3600);if(count>20)throw failure(429,'Email hourly limit reached.');
        const once=await command('SET',key('send:'+session.sub+':'+requestId),'pending','NX','EX',86400);if(!once)throw failure(409,'This send was already submitted. Check Sent in Gmail before trying again.');
        const raw=Buffer.from('To: '+to+'\r\nSubject: =?UTF-8?B?'+Buffer.from(subject).toString('base64')+'?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n'+Buffer.from(message).toString('base64')).toString('base64url');
        const result=await provider('https://gmail.googleapis.com/gmail/v1/users/me/messages/send',{method:'POST',headers:{Authorization:'Bearer '+account.access,'Content-Type':'application/json'},body:JSON.stringify({raw})});
        await put('sent:'+session.sub+':'+requestId,{id:result.id,at:new Date().toISOString()});
        return json(200,{id:result.id,status:'Accepted by Gmail'});
      }
      if(action==='checkout') {
        if(!config.checkout)throw failure(503,'Configure a Stripe secret key and a fixed registry contribution Price ID.');
        if(body.confirm!==true)throw failure(400,'Confirm opening provider checkout.');
        const requestId=String(body.requestId||'');if(!/^[A-Za-z0-9_-]{16,80}$/.test(requestId))throw failure(400,'A unique checkout request is required.');
        const params=new URLSearchParams({mode:'payment','line_items[0][price]':env.STRIPE_REGISTRY_PRICE_ID,'line_items[0][quantity]':'1',success_url:env.APP_ORIGIN+'/journey.html?checkout={CHECKOUT_SESSION_ID}#imports',cancel_url:env.APP_ORIGIN+'/journey.html?checkout=cancelled#imports',client_reference_id:session.sub,'metadata[owner]':session.sub});
        const checkout=await provider('https://api.stripe.com/v1/checkout/sessions',{method:'POST',headers:{Authorization:'Bearer '+env.STRIPE_SECRET_KEY,'Content-Type':'application/x-www-form-urlencoded','Idempotency-Key':'cobrides-'+session.sub+'-'+requestId},body:params});
        if(!checkout.url?.startsWith('https://checkout.stripe.com/'))throw failure(502,'Stripe did not return a hosted checkout URL.');
        return json(200,{url:checkout.url});
      }
      if(action==='checkout-status') {
        if(!config.checkout)throw failure(503,'Stripe is not configured.');const id=url.searchParams.get('id');if(!/^cs_(test_|live_)?[A-Za-z0-9]+$/.test(id||''))throw failure(400,'Invalid checkout reference.');
        const data=await provider('https://api.stripe.com/v1/checkout/sessions/'+id,{headers:{Authorization:'Bearer '+env.STRIPE_SECRET_KEY}});
        if(data.metadata?.owner!==session.sub)throw failure(403,'This checkout belongs to another account.');
        return json(200,{id:data.id,status:data.payment_status,amount:data.amount_total,currency:data.currency});
      }
      throw failure(404,'Unknown integration action.');
    }catch(error){return json(error.status||500,{error:error.status?error.message:'The integration service is unavailable. Please retry later.'});}
  };
}
module.exports=createHandler();
module.exports.createHandler=createHandler;
module.exports.seal=seal;module.exports.unseal=unseal;module.exports.configuration=configuration;
module.exports.config={api:{bodyParser:false}};
