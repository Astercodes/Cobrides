/* Shared decision entry for invited collaborators and professional accounts. */
let dpProjects=[],dpSelected='';
const escapeHTML=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const activeProject=()=>({id:dpSelected});
const heading=(title,description)=>'<section class="sd-portal-heading"><h1>'+escapeHTML(title)+'</h1><p>'+escapeHTML(description)+'</p></section>';
const projectBar=()=>'',financeCurrency=()=> 'USD',formatDate=value=>new Date(value+'T12:00:00').toLocaleDateString();
function field(name,label,type='text',value=''){return '<label class="field">'+escapeHTML(label)+(type==='textarea'?'<textarea name="'+escapeHTML(name)+'">'+escapeHTML(value)+'</textarea>':'<input name="'+escapeHTML(name)+'" type="'+escapeHTML(type)+'" value="'+escapeHTML(value)+'">')+'</label>';}
let decisionPageIII=()=>'<p>Opening your decisions...</p>';
async function wpRequest(path,body){const session=await CoBridesAuth.current();if(!session)throw Error('Sign in again to open this wedding.');return CoBridesAuth.request(path,body,session);}
async function wpEnsure(id){const rows=await wpRequest('/rest/v1/cb_projects?select=id,title,owner_id,archived_at&id=eq.'+encodeURIComponent(id));if(!rows.length)throw Error('You no longer have access to this wedding.');return rows[0];}
function render(){document.querySelector('#decision-app').innerHTML=dpSelected?decisionPageIII():'<section class="panel"><h1>Your shared decisions</h1><p>Accept a wedding invitation to see proposals shared with you.</p><a class="button" href="collaborate.html">Open your wedding workspace</a></section>';}
window.CoBridesDecisionReady=async()=>{try{dpProjects=await wpRequest('/rest/v1/cb_projects?select=id,title&order=created_at.desc');const requested=new URLSearchParams(location.search).get('project');dpSelected=dpProjects.some(p=>p.id===requested)?requested:dpProjects[0]?.id||'';document.querySelector('#decision-project').innerHTML=dpProjects.map(p=>'<option value="'+p.id+'" '+(p.id===dpSelected?'selected':'')+'>'+escapeHTML(p.title)+'</option>').join('');dpBack(true);render();}catch(error){document.querySelector('#decision-app').textContent=error.message;}};
function dpBack(keepDecision=false){const decision=keepDecision?new URLSearchParams(location.search).get('decision'):null;document.querySelector('#decision-back').href='collaborate.html?project='+encodeURIComponent(dpSelected);history.replaceState(null,'','decisions.html?project='+encodeURIComponent(dpSelected)+(decision?'&decision='+encodeURIComponent(decision):'')+'#decisions');}
document.querySelector('#decision-project').addEventListener('change',event=>{document.querySelector('#ca-dialog')?.close();dpSelected=event.target.value;dpBack();render();});
document.addEventListener('click',event=>{if(event.target.closest('[data-ca-close]'))document.querySelector('#ca-dialog')?.close();});
