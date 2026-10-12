(function(root){
'use strict';
const roles=['Bride','Partner','Wedding Planner','Bridal Party','Family','Vendor','Merchant','Guest','Venue','Platform Admin'];
function migrate(s){s.portalPlans ||= {plannerProjects:[]};s.portalPlans.plannerProjects ||= [];return s;}
function view(s,role,personId,projectId){
 const project=s.projects.find(p=>p.id===projectId);if(!project)return {};
 const rows=k=>(s[k]||[]).filter(r=>r.projectId===projectId);
 const person=(s.contacts||[]).find(c=>c.id===personId);
 const own=r=>!!person&&(r.owner===person.id||r.stakeholderId===person.id||r.ownerId===person.id||r.personId===person.id||r.vendorId===person.id||r.merchantId===person.id||r.contactId===person.id||r.participantIds?.includes(person.id));
 const eventIds=person?.eventIds||[];
 const scopedEvents=rows('events').filter(e=>eventIds.includes(e.id));
 const full=['Bride','Partner'].includes(role);
 if(role==='Platform Admin')return {counts:{projects:s.projects.length,contacts:(s.contacts||[]).length,vendors:(s.contacts||[]).filter(c=>['Vendor','Venue','Merchant'].includes(c.role)).length},sections:[]};
 const sections=[];const add=(title,records,route)=>sections.push({title,route,records:records.map(r=>({id:r.id,title:r.title||r.name||(s.purchases||[]).find(i=>i.id===r.itemId)?.title||(s.contacts||[]).find(c=>c.id===r.vendorId)?.name||'Recorded service',status:r.status||(r.done?'Complete':'Open')}))});
 add('Your assignments',rows('tasks').filter(r=>full||own(r)),'tasks');
 add('Celebrations & schedules',full?rows('events'):scopedEvents,'events');
 if(full||['Family','Wedding Planner'].includes(role))add('Decisions awaiting your attention',rows('decisions').filter(r=>full||r.approverIds?.includes(personId)),'decisions');
 if(full||['Vendor','Venue','Wedding Planner'].includes(role)){add('Bookings',rows('vendorBookings').filter(r=>full||own(r)),'vendors');add('Coordination instructions',rows('vendorInstructions').filter(r=>full||own(r)),'vendor-workspace');}
 if(full||role==='Vendor')add('Quotations',rows('vendorQuotes').filter(r=>full||own(r)),'vendors');
 if(full||['Bridal Party','Family'].includes(role))add('Outfits & styling',rows('wardrobeLooks').filter(r=>full||own(r)),'wardrobe');
 if(full||['Bridal Party','Family'].includes(role))add('Contribution commitments',rows('contributions').filter(r=>full||(!r.private&&!r.anonymous&&r.privacy!=='Private'&&r.privacy!=='Anonymous'&&own(r))),'contributions');
 if(full||role==='Merchant')add('Orders',rows('shoppingOrders').filter(r=>full||own(r)),'shopping');
 if(full||role==='Vendor')add('Media deliverables',rows('memoryDeliverables').filter(r=>full||own(r)),'memories');
 if(full)add('Financial obligations',rows('obligations'),'payments');
 if(role==='Guest')add('Your invitations',(s.guests||[]).filter(g=>g.projectId===projectId&&g.id===personId),'guests');
 return {project,sections};
}
const api={roles,migrate,view};if(typeof module==='object'&&module.exports)module.exports=api;else root.PortalCore=api;
})(typeof window==='object'?window:globalThis);
