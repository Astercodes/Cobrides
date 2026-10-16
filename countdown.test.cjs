const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('planning.js','utf8'),start=source.indexOf('function updateCountdowns()'),end=source.indexOf('\nsetInterval(updateCountdowns',start);
let now=Date.parse('2027-06-18T22:58:59Z');
class Clock extends Date{static now(){return now}}
function element(includeSeconds){const nodes=Object.fromEntries(['days','hours','minutes',...(includeSeconds?['seconds']:[])].map(unit=>[unit,{textContent:'—'}]));return {dataset:{countdown:'2027-06-19T00:00:00Z'},nodes,querySelector(selector){return nodes[selector.match(/"(.*?)"/)[1]]||null},setAttribute(name,value){this[name]=value}}}
const live=element(true),legacy=element(false),context={Date:Clock,document:{querySelectorAll:()=>[live,legacy]}};
vm.createContext(context);vm.runInContext(source.slice(start,end),context);context.updateCountdowns();
assert.equal(live.nodes.hours.textContent,'01');assert.equal(live.nodes.minutes.textContent,'01');assert.equal(live.nodes.seconds.textContent,'01');
now+=1000;context.updateCountdowns();assert.equal(live.nodes.seconds.textContent,'00');
now+=1000;context.updateCountdowns();assert.equal(live.nodes.minutes.textContent,'00');assert.equal(live.nodes.seconds.textContent,'59');
assert(legacy['aria-label'].includes('minutes remaining'));assert(!legacy['aria-label'].includes('seconds'));
now=Date.parse('2027-06-19T00:00:01Z');context.updateCountdowns();assert(Object.values(live.nodes).every(node=>node.textContent==='00'));assert.equal(live['aria-label'],'The selected date has arrived');
console.log('Countdown passed: ticking seconds, minute rollover, legacy three-unit displays and elapsed dates.');
