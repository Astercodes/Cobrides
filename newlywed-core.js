(function(root){'use strict';
const kinds=['Transition tasks','Household budget','Savings goals','Responsibilities & routines','Milestones & celebrations','Travel & experiences','Traditions & holidays','Learning & enrichment'];
function migrate(s){s.newlywedPlans ||= [];s.newlywedRecords ||= [];}
function scope(s,pid,kind){return (s.newlywedRecords||[]).filter(r=>r.projectId===pid&&(!kind||r.kind===kind));}
function validate(r){if(!r.title?.trim()||!kinds.includes(r.kind))throw Error('Add a title and valid category.');for(const key of ['amount','target','saved'])if(!Number.isFinite(r[key])||r[key]<0)throw Error('Use nonnegative amounts.');if(!Number.isInteger(r.interval)||r.interval<0||r.interval>365)throw Error('Use a repeat interval from 0 to 365 whole days.');if(r.date&&(!/^\d{4}-\d{2}-\d{2}$/.test(r.date)||new Date(r.date+'T12:00:00Z').toISOString().slice(0,10)!==r.date))throw Error('Use a valid calendar date.');if(r.url&&new URL(r.url).protocol!=='https:')throw Error('Use an HTTPS resource URL.');}
function next(r,addDays){if(!r.date||['Complete','Paused'].includes(r.status))return '';let date=r.date;while(r.interval&&(r.checkins||[]).includes(date))date=addDays(date,r.interval);return date;}
function budget(s,pid){const rows=scope(s,pid,'Household budget').filter(r=>r.status!=='Paused'),income=rows.filter(r=>r.flow==='Income').reduce((n,r)=>n+r.amount,0),expenses=rows.filter(r=>r.flow!=='Income').reduce((n,r)=>n+r.amount,0);return {income,expenses,remaining:income-expenses,annualExpenses:expenses*12};}
const api={kinds,migrate,scope,validate,next,budget};if(typeof module==='object'&&module.exports)module.exports=api;else root.NewlywedCore=api;
})(typeof window==='object'?window:globalThis);
