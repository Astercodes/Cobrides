const assert=require('node:assert/strict'),PC=require('./planning-core'),CC=require('./collaboration-core'),FC=require('./finance-core'),VC=require('./vendor-core');
let n=0;const id=()=>`vendor-${++n}`,s={profile:{name:'Personal name'},projects:[{id:'real',title:'Personal wedding',phases:['Dream']}],activeProjectId:'real',tasks:[],expenses:[],contacts:[],guests:[],purchases:[],visions:[]};
PC.migrate(s,id);require('./planning-samples').seed(s,id,'2026-10-14',PC);CC.migrate(s);require('./collaboration-samples').seed(s,id,'2026-10-14',PC,CC);FC.migrate(s,id);require('./finance-samples').seed(s,id,'2026-10-14',PC,FC);VC.migrate(s);
const Samples=require('./vendor-samples'),expenseCount=s.expenses.length,ledgerCount=s.financeTransactions.length,profile=structuredClone(s.profile);
assert(Samples.seed(s,id,'2026-10-14',PC,VC,FC));
for(const p of s.projects.filter(p=>p.sample)){
 const contacts=s.contacts.filter(c=>c.projectId===p.id),quotes=s.vendorQuotes.filter(q=>q.projectId===p.id),bookings=s.vendorBookings.filter(b=>b.projectId===p.id),instructions=s.vendorInstructions.filter(i=>i.projectId===p.id);
 for(const category of VC.categories)assert(contacts.some(c=>c.vendorProfile?.category===category&&c.vendorProfile.services&&c.vendorProfile.image));
 assert(quotes.length>=7);assert(quotes.some(q=>q.status==='Negotiating'));assert(quotes.some(q=>q.validUntil<'2026-10-14'));assert.equal(instructions.length,7);
 for(const q of quotes){VC.validateQuote(q);assert(contacts.some(c=>c.id===q.vendorId));assert(q.sample);}
 for(const b of bookings){const e=s.expenses.find(e=>e.id===b.expenseId),q=quotes.find(q=>q.id===b.quoteId);assert(e&&q);assert.equal(q.vendorId,e.vendorId);assert.equal(q.amountNative,e.originalAmount);assert.equal(q.currency,e.currency);assert.equal(q.rateToBase,e.rateToBase);}
 for(const i of instructions){assert(!VC.cycle(instructions,i.id,i.dependencies));for(const a of i.acknowledgements){assert(i.participantIds.includes(a.personId));assert.equal(a.version,i.version);}if(i.status==='Complete')assert(VC.readiness(instructions,i).ready);}
 assert(instructions.some(i=>i.version===2&&i.history.length&&VC.readiness(instructions,i).pending.length));
 const tasks=s.tasks.filter(t=>t.projectId===p.id&&t.title.startsWith('Vendor brief:'));assert.equal(tasks.length,6);assert.equal(new Set(tasks.map(t=>t.status)).size,4);for(const t of tasks)for(const v of t.vendorIds)assert(contacts.some(c=>c.id===v));
 assert.equal(s.vendorChanges.filter(c=>c.projectId===p.id).length,4);
 for(const r of s.vendorReviews.filter(r=>r.projectId===p.id))assert(bookings.some(b=>b.vendorId===r.vendorId&&b.status==='Completed'));
 console.log(JSON.stringify({project:p.title,professionals:contacts.filter(c=>c.vendorProfile).length,proposals:quotes.length,serviceRecords:bookings.length,sharedInstructions:instructions.length,vendorTasks:tasks.length}));
}
assert.equal(s.expenses.length,expenseCount);assert.equal(s.financeTransactions.length,ledgerCount);assert.deepEqual(s.profile,profile);assert.throws(()=>VC.book(s,s.vendorQuotes[0].id,id,'2026-10-14'),/Sample/);
const snapshot=JSON.stringify(s);assert.equal(Samples.seed(s,id,'2026-10-15',PC,VC,FC),false);assert.equal(JSON.stringify(s),snapshot);
console.log('Vendor samples passed: all categories, coherent finance links, dependency/acknowledgement integrity, scoped records, no duplicate expenses and one-time seeding.');
