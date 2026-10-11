const fs = require('node:fs');
const path = require('node:path');
const output = path.join(__dirname, 'dist');
fs.mkdirSync(output, { recursive: true });
for (const file of ['index.html', 'journey.html', 'style.css', 'bold.css', 'landing.css', 'landing.js', 'app.js', 'planning-core.js', 'planning.js', 'planning.css', 'collaboration-core.js', 'collaboration.js', 'collaboration.css', 'finance-core.js', 'finance.js', 'finance.css', 'landing-world.js', 'world.css', 'vendor-core.js', 'vendors.js', 'vendors.css', 'commerce-core.js', 'commerce.js', 'commerce.css', 'guest-core.js', 'guest-experience.js', 'guest-experience.css', 'registry-core.js', 'registry.js']) {
  fs.copyFileSync(path.join(__dirname, file), path.join(output, file));
}
fs.cpSync(path.join(__dirname, 'assets'), path.join(output, 'assets'), { recursive: true });
console.log('FURBRIDES static build ready in dist/');
