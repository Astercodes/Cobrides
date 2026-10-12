const fs = require('node:fs');
const path = require('node:path');
const output = path.join(__dirname, 'dist');
fs.mkdirSync(output, { recursive: true });
const staticFiles=['index.html', 'journey.html', 'style.css', 'bold.css', 'landing.css', 'landing.js', 'app.js', 'planning-core.js', 'planning.js', 'planning.css', 'collaboration-core.js', 'collaboration.js', 'collaboration.css', 'finance-core.js', 'finance.js', 'finance.css', 'landing-world.js', 'world.css', 'vendor-core.js', 'vendors.js', 'vendors.css', 'commerce-core.js', 'commerce.js', 'commerce.css', 'guest-core.js', 'guest-experience.js', 'guest-experience.css', 'registry-core.js', 'registry.js', 'preparation-core.js', 'preparation.js', 'preparation.css', 'operations-core.js', 'operations.js', 'memories.js', 'operations.css', 'platform-core.js', 'platform.js', 'platform-offline.js', 'platform.css', 'offline-worker.js'];
for (const file of staticFiles) {
  fs.copyFileSync(path.join(__dirname, file), path.join(output, file));
}
fs.cpSync(path.join(__dirname, 'assets'), path.join(output, 'assets'), { recursive: true });
console.log('FURBRIDES static build ready in dist/');

const crypto = require('node:crypto');
function offlineFiles(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(entry=>entry.isDirectory()?offlineFiles(path.join(dir,entry.name)):[path.join(dir,entry.name)]);}
const offlineList=[...staticFiles,...offlineFiles(path.join(__dirname,'assets')).map(file=>path.relative(__dirname,file).split(path.sep).join('/'))].filter(file=>!['offline-worker.js','offline-manifest.json'].includes(file)).sort();
const offlineHash=crypto.createHash('sha256');for(const file of offlineList)offlineHash.update(file).update(fs.readFileSync(path.join(output,file)));
const offlineVersion=offlineHash.digest('hex').slice(0,16),offlineManifest=JSON.stringify({version:offlineVersion,files:offlineList},null,2);
fs.writeFileSync(path.join(output,'offline-manifest.json'),offlineManifest);fs.writeFileSync(path.join(__dirname,'offline-manifest.json'),offlineManifest);
fs.writeFileSync(path.join(output,'offline-worker.js'),fs.readFileSync(path.join(__dirname,'offline-worker.js'),'utf8').replace('__OFFLINE_BUILD__',offlineVersion));
