(function(root){'use strict';
function migrate(s){s.honeymoonPlans ||= [];s.honeymoonRecords ||= [];}
function validate(r,plan){if(!r.title?.trim())throw Error('Add a record title.');if(r.date&&(!/^\d{4}-\d{2}-\d{2}$/.test(r.date)||new Date(r.date+'T12:00:00Z').toISOString().slice(0,10)!==r.date))throw Error('Choose a valid date.');if(r.kind==='Itinerary'&&r.date&&((plan.start&&r.date<plan.start)||(plan.end&&r.date>plan.end)))throw Error('Keep itinerary activities within your travel dates.');if(!Number.isFinite(r.cost)||r.cost<0||!Number.isFinite(r.rate)||r.rate<=0)throw Error('Use a nonnegative cost and a positive exchange rate.');}
function days(start,end){if(!start||!end)return 0;return Math.round((Date.parse(end+'T12:00:00Z')-Date.parse(start+'T12:00:00Z'))/86400000)+1;}
function scope(s,pid,kind){return (s.honeymoonRecords||[]).filter(r=>r.projectId===pid&&(!kind||r.kind===kind));}
function budget(s,pid){const p=s.honeymoonPlans.find(p=>p.projectId===pid)||{},rows=scope(s,pid).filter(r=>r.kind!=='Destination'&&!r.cancelled&&r.status!=='Cancelled'),estimated=rows.reduce((n,r)=>{const e=(s.expenses||[]).find(e=>e.id===r.expenseId&&e.projectId===pid);return n+(e?(e.status==='Cancelled'?0:Number(e.amount)||0):r.cost*r.rate);},0);return {target:Number(p.budget)||0,estimated,remaining:(Number(p.budget)||0)-estimated};}
const api={migrate,validate,days,scope,budget};if(typeof module==='object'&&module.exports)module.exports=api;else root.HoneymoonCore=api;
})(typeof window==='object'?window:globalThis);
