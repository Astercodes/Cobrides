(function (root) {
  'use strict';
  const dayMs = 86400000;
  function addDays(date, days) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date || '')) return '';
    const value = new Date(date + 'T12:00:00Z');
    if (!Number.isFinite(value.getTime())) return '';
    value.setUTCDate(value.getUTCDate() + Number(days));
    return value.toISOString().slice(0, 10);
  }
  function diffDays(a, b) {
    return Math.round((new Date(a + 'T12:00:00Z') - new Date(b + 'T12:00:00Z')) / dayMs);
  }
  function migrate(state, makeId) {
    state.projects ||= [];
    if (!state.projects.length) state.projects.push({id:makeId(),title:'My wedding journey',date:state.profile.date || '',dateStatus:state.profile.date?'Confirmed':'Projected',budget:Number(state.profile.budget)||0,anniversary:'',candidateDates:[],phases:['Dream','Prepare','Confirm','Celebrate']});
    if (!state.projects.some(p=>p.id===state.activeProjectId)) state.activeProjectId=state.projects[0].id;
    state.events ||= []; state.decisions ||= []; state.activity ||= [];
    state.planningSettings ||= {reminderDays:7};
    state.planningSettings.rules ||= {eventConfirmed:true,expensePaid:true,purchaseBought:true};
    state.workflowKeys ||= [];
    for (const task of state.tasks) {
      task.projectId ||= state.projects[0].id;
      task.status ||= task.done?'Done':'To do';
      task.priority ||= 'Normal'; task.dependencies ||= []; task.duration ||= 1;
      task.subtasks ||= []; task.discussion ||= []; task.attachments ||= [];
      task.approval ||= 'Not required'; task.eventId ||= ''; task.phase ||= 'Prepare';
    }
    for (const kind of ['expenses','contacts','guests','purchases']) for(const item of state[kind]) {
      item.eventIds ||= []; item.projectId ||= state.projects[0].id;
    }
    return state;
  }
  function cycle(tasks, id, dependencies) {
    const graph = new Map(tasks.map(t=>[t.id,t.id===id?dependencies:t.dependencies||[]]));
    graph.set(id,dependencies);
    const visiting=new Set(),visited=new Set();
    function visit(key){if(visiting.has(key))return true;if(visited.has(key))return false;visiting.add(key);for(const dependency of graph.get(key)||[])if(graph.has(dependency)&&visit(dependency))return true;visiting.delete(key);visited.add(key);return false;}
    return [...graph.keys()].some(visit);
  }
  function blocked(task, tasks) {
    return (task.dependencies||[]).filter(id=>!tasks.find(t=>t.id===id)?.done);
  }
  function schedule(project, tasks, events, overrideDate, contacts=[]) {
    const results=new Map(),visiting=new Set();
    function due(task){
      if(results.has(task.id))return results.get(task.id);
      if(visiting.has(task.id))return {date:task.due||'',conflict:true};
      visiting.add(task.id);
      let event=events.find(e=>e.id===task.eventId);
      if(event?.scheduleMode==='Relative')event={...event,date:(overrideDate||project.date)?addDays(overrideDate||project.date,event.daysOffset||0):''};
      const anchor=task.anchor==='Event'?event?.date:(overrideDate||project.date);
      const automatic=task.scheduleMode==='Relative';
      let date=automatic?(anchor?addDays(anchor,-Number(task.daysBefore||0)):''):(task.due||'');
      let conflict=false;
      for(const id of task.dependencies||[]){const previous=tasks.find(t=>t.id===id);if(!previous)continue;const predecessor=previous.done&&previous.completedDate?{date:previous.completedDate}:due(previous);if(predecessor.date&&date){const earliest=addDays(predecessor.date,Math.max(1,Number(task.duration)||1));if(earliest>date){if(automatic)date=earliest;else conflict=true;}}}
      const unavailable=new Set(contacts.filter(c=>(task.vendorIds||[]).includes(c.id)).flatMap(c=>c.unavailableDates||[]));
      if(date&&unavailable.has(date)){if(automatic){let attempts=0;while(unavailable.has(date)&&attempts<366){date=addDays(date,1);attempts++;}if(unavailable.has(date))conflict=true;}else conflict=true;}
      if(anchor&&date>anchor)conflict=true;
      visiting.delete(task.id);const result={date,conflict};results.set(task.id,result);return result;
    }
    tasks.forEach(due);return results;
  }
  function criticalPath(tasks) {
    const remaining=tasks.filter(t=>!t.done),finish=new Map();
    const visiting=new Set();
    function path(task){if(finish.has(task.id))return finish.get(task.id);if(visiting.has(task.id))return {length:0,ids:[]};visiting.add(task.id);let best={length:0,ids:[]};for(const id of task.dependencies||[]){const p=remaining.find(t=>t.id===id);if(p){const chain=path(p);if(chain.length>best.length)best=chain;}}visiting.delete(task.id);const value={length:best.length+Math.max(1,Number(task.duration)||1),ids:[...best.ids,task.id]};finish.set(task.id,value);return value;}
    let longest={length:0,ids:[]};remaining.forEach(t=>{const chain=path(t);if(chain.length>longest.length)longest=chain;});return longest;
  }
  function eventSpend(eventId, expenses) {return expenses.filter(e=>(e.eventIds||[]).includes(eventId)).reduce((sum,e)=>sum+Number(e.amount||0)/(e.eventIds.length||1),0);}
  function vendorConflicts(events, contacts) {
    const conflicts=[];
    for(let a=0;a<events.length;a++)for(let b=a+1;b<events.length;b++){
      const x=events[a],y=events[b];
      if(!x.date||x.date!==y.date)continue;
      // Missing times are treated as all-day, rather than silently assumed available.
      const overlap=!x.time||!y.time||!x.endTime||!y.endTime||(x.time<y.endTime&&y.time<x.endTime);
      if(overlap)for(const c of contacts)if(c.role==='Vendor'&&c.eventIds?.includes(x.id)&&c.eventIds?.includes(y.id))conflicts.push({vendor:c.name,events:[x.title,y.title]});
    }
    return conflicts;
  }
  function workflowSuggestions(state) {
    const results=[],rules=state.planningSettings.rules,seen=new Set(state.workflowKeys);
    const add=(key,item)=>{if(!seen.has(key))results.push({key,...item});};
    if(rules.eventConfirmed)for(const e of state.events)if(e.status==='Confirmed')add(`event:${e.id}:confirmed`,{title:`Prepare the ${e.title} run sheet`,category:'Operations',projectId:e.projectId,eventId:e.id,owner:e.owner||''});
    if(rules.expensePaid)for(const e of state.expenses)if(e.status==='Paid')add(`expense:${e.id}:paid`,{title:`File the receipt for ${e.title}`,category:'Budget',projectId:e.projectId,eventId:e.eventIds?.[0]||'',owner:''});
    if(rules.purchaseBought)for(const p of state.purchases)if(p.bought)add(`purchase:${p.id}:bought`,{title:`Check delivery / collection of ${p.title}`,category:'Shopping',projectId:p.projectId,eventId:p.eventIds?.[0]||'',owner:''});
    return results;
  }
  const api={addDays,diffDays,migrate,cycle,blocked,schedule,criticalPath,eventSpend,vendorConflicts,workflowSuggestions};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.PlanningCore=api;
})(typeof window!=='undefined'?window:globalThis);
