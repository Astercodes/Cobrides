'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.join(__dirname,'android/app/build'),apk=path.join(root,'outputs/apk/debug/app-debug.apk');
const certificate=fs.readFileSync(path.join(root,'certificate.txt'),'utf8');
const raw=certificate.match(/Signer #1 certificate SHA-256 digest:\s*([a-f0-9]{64})/i)?.[1];
if(!raw)throw Error('No verified Android signing certificate was found.');
const fingerprint=raw.toUpperCase().match(/.{2}/g).join(':');
const out=path.join(__dirname,'artifacts');fs.mkdirSync(out,{recursive:true});
fs.copyFileSync(apk,path.join(out,'Cobridey-Android-Beta.apk'));
fs.writeFileSync(path.join(out,'assetlinks.beta.json'),JSON.stringify([{
 relation:['delegate_permission/common.handle_all_urls'],
 target:{namespace:'android_app',package_name:'com.cobridey.app.beta',sha256_cert_fingerprints:[fingerprint]}
}],null,2)+'\n');
fs.writeFileSync(path.join(out,'build.json'),JSON.stringify({
 applicationId:'com.cobridey.app.beta',commit:process.env.CB_BUILD_COMMIT||null,
 sha256:crypto.createHash('sha256').update(fs.readFileSync(apk)).digest('hex'),certificate:fingerprint,
 startUrl:'https://www.cobridey.com/journey.html#home',distribution:'internal testing only'
},null,2)+'\n');
fs.writeFileSync(path.join(out,'READ-ME.txt'),[
 'Cobridey Android Beta — internal testing only',
 'Install Cobridey-Android-Beta.apk on an Android phone (Android 7 or newer).',
 'Use Chrome or another browser that supports Trusted Web Activities.',
 'The app opens the real Cobridey website and uses real accounts. Existing access controls apply.',
 'The browser bar remains until the exact signing certificate in assetlinks.beta.json is published at https://www.cobridey.com/.well-known/assetlinks.json.',
 'No security-verification bypass is used. External websites display browser identity controls.',
 'This build uses a temporary debug key. A later beta may need uninstalling before installation.',
 'Do not uninstall with unsynced changes. Production signing will use a separately protected owner-controlled key.',
 'Test password and Google login, logout, uploads, export, external links, back navigation, offline/reconnect and account isolation.',
 'Push notifications, store billing, share-to-Cobridey and the iPhone app are not included in this first build.',
 'No private signing key is included in this download.'
].join('\n')+'\n');
console.log('Verified beta APK, public certificate and installation notes prepared.');
