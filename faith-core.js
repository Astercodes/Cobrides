(function(root){'use strict';
const kinds=['Prayer & devotional plan','Scripture & reading','Journal & gratitude','Prayer request','Counseling & classes','Ceremony & vows','Mentors & groups','Voluntary discipline','Marriage reflections'];
function migrate(s){s.faithProfiles ||= [];s.faithRecords ||= [];}
function scope(s,pid,kind){return (s.faithRecords||[]).filter(r=>r.projectId===pid&&(!kind||r.kind===kind));}
function validate(r){if(!r.title?.trim())throw Error('Add a title.');if(!kinds.includes(r.kind))throw Error('Choose a preparation category.');if(!Number.isInteger(r.interval)||r.interval<0||r.interval>365)throw Error('Use a whole repeat interval from 0 to 365 days.');if(r.date&&(!/^\d{4}-\d{2}-\d{2}$/.test(r.date)||new Date(r.date+'T12:00:00Z').toISOString().slice(0,10)!==r.date))throw Error('Choose a valid date.');if(r.url){let u;try{u=new URL(r.url);}catch{throw Error('Use a complete HTTPS teaching or resource URL.');}if(u.protocol!=='https:')throw Error('Use an HTTPS resource link.');}}
function next(r,addDays){if(!r.date||['Complete','Answered','Paused'].includes(r.status))return '';if(!r.interval)return r.date;let date=r.date;const checks=new Set(r.checkins||[]);while(checks.has(date))date=addDays(date,r.interval);return date;}
function checkin(r,date){if(!/^\d{4}-\d{2}-\d{2}$/.test(date))throw Error('Choose a valid check-in date.');r.checkins ||= [];if(!r.checkins.includes(date))r.checkins.push(date);}
const api={kinds,migrate,scope,validate,next,checkin};if(typeof module==='object'&&module.exports)module.exports=api;else root.FaithCore=api;
})(typeof window==='object'?window:globalThis);
