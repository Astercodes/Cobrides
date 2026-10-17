'use strict';
function publicKey(key){if(/^sb_publishable_[A-Za-z0-9_-]+$/.test(key))return true;try{return JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString()).role==='anon';}catch{return false;}}
function handler(req,res){const url=process.env.SUPABASE_URL||'',key=process.env.SUPABASE_PUBLISHABLE_KEY||'';const configured=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)&&publicKey(key);res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');res.end(JSON.stringify(configured?{configured,url,key}:{configured:false}));}
module.exports=handler;module.exports.publicKey=publicKey;
