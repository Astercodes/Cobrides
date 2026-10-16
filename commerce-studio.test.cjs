const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),SC=require('./commerce-core');
const context={};vm.createContext(context);vm.runInContext(fs.readFileSync('commerce-studio.js','utf8'),context);
for(const category of SC.categories){const result=context.commerceStudioPhotoSource({category,title:category+' · the jewel-tone edit'});assert(fs.existsSync(result.url),category+' needs a local image');assert.equal(result.uploaded,false);}
assert.equal(context.commerceStudioPhotoSource({category:'Traditional attire',title:'The jewel-tone celebration set'}).url,'assets/products/traditional.webp');
assert.equal(context.commerceStudioPhotoSource({category:'Bridesmaid dress',title:'Six jewel-tone bridesmaid dresses'}).url,'assets/products/bridesmaids.webp');
assert.equal(context.commerceStudioPhotoSource({category:'Groom & groomsmen',title:'Tobi’s teal ceremony tuxedo'}).url,'assets/products/groom.webp');
const upload='data:image/png;base64,aGVsbG8=';assert.equal(context.commerceStudioPhotoSource({category:'Wedding gown',attachments:[{url:upload}]}).url,upload);
assert.equal(context.commerceStudioPhotoSource({category:'Shoes',attachments:[{url:'javascript:alert(1)'}]}).url,'assets/products/shoes.webp');
console.log('Commerce images passed: category coverage, jewel-tone garments, uploaded-photo priority, and safe fallback.');
