const test=require('node:test'),assert=require('node:assert/strict'),C=require('./onboarding-core');
test('profile photo survives onboarding draft and completion without being replaced by a demo image',()=>{
 const identity={user:{id:'new-user'},profile:{full_name:'Ada'}},photo='cb-file:v1:cb-documents/new-user/photo-image_jpeg';
 const defaults=C.defaults({onboarding:{draft:{avatarUrl:photo}}},identity);
 assert.equal(defaults.avatarUrl,photo);
 const result=C.build(null,identity,{...defaults,stage:'Engaged',title:'Our wedding'},()=>crypto.randomUUID(),new Date().toISOString());
 assert.equal(result.profile.avatarUrl,photo);
 assert(!result.profile.sample);
});
