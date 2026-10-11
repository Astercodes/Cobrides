const assert=require('node:assert/strict');
const PC=require('./planning-core');

// Migration must preserve the original account's private preparations.
const legacy={profile:{date:'2027-06-19',budget:25000},tasks:[{id:'old-task',title:'Save dress ideas',done:true}],expenses:[{id:'expense',amount:1000}],contacts:[],guests:[],purchases:[],visions:[{id:'vision'}]};
let serial=0;PC.migrate(legacy,()=>`id-${++serial}`);
assert.equal(legacy.projects.length,1);assert.equal(legacy.tasks[0].done,true);assert.equal(legacy.tasks[0].status,'Done');assert.equal(legacy.visions[0].id,'vision');assert.equal(legacy.expenses[0].amount,1000);
const firstProject=legacy.activeProjectId;PC.migrate(legacy,()=>`id-${++serial}`);assert.equal(legacy.projects.length,1);assert.equal(legacy.activeProjectId,firstProject);

assert.equal(PC.addDays('2028-02-28',1),'2028-02-29');assert.equal(PC.addDays('2027-12-31',1),'2028-01-01');assert.equal(PC.diffDays('2027-03-15','2027-03-13'),2);
const project={date:'2027-06-19'};
const tasks=[{id:'a',scheduleMode:'Relative',daysBefore:30,duration:3,dependencies:[],done:false},{id:'b',scheduleMode:'Relative',daysBefore:29,duration:4,dependencies:['a'],done:false},{id:'c',scheduleMode:'Manual',due:'2027-05-21',duration:1,dependencies:['b'],done:false}];
const schedule=PC.schedule(project,tasks,[]);
assert.equal(schedule.get('a').date,'2027-05-20');assert.equal(schedule.get('b').date,'2027-05-24');assert.equal(schedule.get('c').date,'2027-05-21');assert.equal(schedule.get('c').conflict,true);
const preview=PC.schedule(project,tasks,[],'2027-07-19');assert.equal(preview.get('a').date,'2027-06-19');assert.equal(preview.get('c').date,'2027-05-21');assert.equal(project.date,'2027-06-19');
const eventTask={id:'event-task',scheduleMode:'Relative',anchor:'Event',eventId:'event-1',daysBefore:7,dependencies:[]};assert.equal(PC.schedule(project,[eventTask],[{id:'event-1',date:'2027-06-18'}],'2027-08-19').get('event-task').date,'2027-06-11');
assert.equal(PC.schedule(project,[eventTask],[{id:'event-1',scheduleMode:'Relative',daysOffset:-1}],'2027-08-19').get('event-task').date,'2027-08-11');
assert.equal(PC.cycle(tasks,'a',['c']),true);assert.equal(PC.cycle(tasks,'c',['a']),false);
assert.deepEqual(PC.blocked(tasks[1],tasks),['a']);tasks[0].done=true;assert.deepEqual(PC.blocked(tasks[1],tasks),[]);
assert.deepEqual(PC.criticalPath(tasks).ids,['b','c']);assert.equal(PC.criticalPath(tasks).length,5);
const shared=[{amount:1000,eventIds:['a','b']},{amount:400,eventIds:['a']}];assert.equal(PC.eventSpend('a',shared),900);assert.equal(PC.eventSpend('b',shared),500);assert.equal(shared.reduce((sum,e)=>sum+e.amount,0),1400);
const contacts=[{role:'Vendor',name:'Shared photographer',eventIds:['a','b']}];assert.equal(PC.vendorConflicts([{id:'a',title:'Ceremony',date:'2027-06-19',time:'10:00',endTime:'12:00'},{id:'b',title:'Reception',date:'2027-06-19',time:'13:00',endTime:'16:00'}],contacts).length,0);assert.equal(PC.vendorConflicts([{id:'a',title:'Ceremony',date:'2027-06-19'},{id:'b',title:'Reception',date:'2027-06-19'}],contacts).length,1);
const vendorTask={id:'vt',scheduleMode:'Relative',daysBefore:30,dependencies:[],vendorIds:['vendor']};const unavailable=[{id:'vendor',unavailableDates:['2027-05-20','2027-05-21']}];assert.equal(PC.schedule(project,[vendorTask],[],null,unavailable).get('vt').date,'2027-05-22');assert.equal(PC.schedule(project,[{...vendorTask,scheduleMode:'Manual',due:'2027-05-20'}],[],null,unavailable).get('vt').conflict,true);
legacy.planningSettings.rules={eventConfirmed:true,expensePaid:true,purchaseBought:true};legacy.events=[{id:'event',title:'Reception',status:'Confirmed',projectId:firstProject}];legacy.expenses[0].status='Paid';legacy.purchases=[{id:'purchase',title:'Veil',bought:true,projectId:firstProject}];const suggestions=PC.workflowSuggestions(legacy);assert.equal(suggestions.length,3);legacy.workflowKeys=suggestions.map(s=>s.key);assert.equal(PC.workflowSuggestions(legacy).length,0);legacy.workflowKeys=[];legacy.planningSettings.rules={eventConfirmed:false,expensePaid:false,purchaseBought:false};assert.equal(PC.workflowSuggestions(legacy).length,0);
console.log('Planning model checks passed: migration, dates, reverse scheduling, scenario isolation, event anchors, dependency cycles, blocking, critical chain, shared allocation and vendor overlap.');
