'use strict';
const plans={monthly:{months:1,amount:6000},quarterly:{months:3,amount:15000},'six-months':{months:6,amount:27000},annual:{months:12,amount:50000}};
function hasPremium(subscription,now=new Date()){return !!(subscription&&subscription.status==='active'&&new Date(subscription.period_start)<=now&&new Date(subscription.period_end)>now);}
function periodEnd(start,plan){const config=plans[plan];if(!config)throw Error('Unknown plan');const date=new Date(start);if(!Number.isFinite(+date))throw Error('Invalid start date');const day=date.getUTCDate();date.setUTCDate(1);date.setUTCMonth(date.getUTCMonth()+config.months);const end=new Date(Date.UTC(date.getUTCFullYear(),date.getUTCMonth()+1,0)).getUTCDate();date.setUTCDate(Math.min(day,end));return date.toISOString();}
module.exports={plans,hasPremium,periodEnd};
