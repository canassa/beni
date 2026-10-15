// An explicit dependency IR. No compiler analysis is claimed by this generator.
export const modes = ['vanilla', 'lexical', 'indexed', 'signals', 'scan', 'expanded'];
export const families = ['dashboard', 'form', 'crud', 'board', 'route', 'fanout'];
export const sizes = [1, 4, 16, 64];

const common = `
const root=document.getElementById('app');
let dead=false;
const scopes=new Set();
function enter(f){if(dead)return;let ok=false;try{f();ok=true}finally{if(!ok){dead=true;for(const s of scopes)s()}}}
function text(n,v){v=String(v);if(n.textContent!==v)n.textContent=v}
function value(n,v){if(n.value!==v)n.value=v}
function mount(html){const t=document.createElement('template');t.innerHTML=html;const n=t.content.firstElementChild;root.append(n);return n}
`;
const network = `
// The narrow API is same-origin GET of JSON, not the complete beni HTTP API.
async function request(url,signal){
 let response;
 try{response=await fetch(url,{signal})}catch(e){
  if(e instanceof DOMException&&e.name==='AbortError')return {error:'Cancelled'};
  if(e instanceof TypeError)return {error:'Network'};
  throw e;
 }
 if(!response.ok)return {error:'Http '+response.status};
 let body;
 try{body=await response.text()}catch(e){
  if(e instanceof DOMException&&e.name==='AbortError')return {error:'Cancelled'};
  if(e instanceof TypeError)return {error:'BodyRead'};
  throw e;
 }
 let data;
 try{data=JSON.parse(body)}catch(e){if(e instanceof SyntaxError)return {error:'BadJson'};throw e}
 if(data===null||typeof data!=='object'||typeof data.title!=='string'||!Number.isSafeInteger(data.count))return {error:'BadBody'};
 return {data};
}
`;
const rows = `
function rowsPatch(parent,items,selected,cache,select){
 const keep=new Set(items.map(x=>x.id));
 for(const [id,r] of cache)if(!keep.has(id)){r.remove();cache.delete(id)}
 let cursor=parent.firstChild;
 for(const item of items){
  let r=cache.get(item.id);
  if(!r){r=document.createElement('button');r.dataset.row=item.id;r.onclick=()=>select(item.id);cache.set(item.id,r)}
  text(r,item.label);r.className=item.id===selected?'selected':'';
  if(r!==cursor)parent.insertBefore(r,cursor);cursor=r.nextSibling;
 }
}
`;
function spec(family, i, diverse, population) {
  const k=diverse ? i : 0;
  const label=diverse ? `${['Revenue','Tickets','Inventory','Sessions','Latency','Quota','Balance','Priority'][i%8]} ${i}` : 'Feature';
  const shell=body=>`<section data-feature="${i}"><h2>${label}</h2>${body}<button data-action="dispose">Dispose</button></section>`;
  const patch=(deps,body)=>({deps,body});
  const action=(name,body,writes, event='click', target=name)=>({name,body,writes,event,target});
  if(family==='dashboard'||family==='fanout')return {
    html:shell('<button data-action="inc">Increment</button><button data-action="toggle">Toggle</button><output></output><progress max="100"></progress>'),
    state:{count:'0',active:'true'},
    setup:`const out=n.querySelector('output'),bar=n.querySelector('progress');`,
    patches:[patch(['count',...(k%2?['active']:[])],`text(out,read('count')*${k%7+1}${k%2?"+(read('active')?1:0)":''});`),patch(['active'],`n.className=read('active')?'active':'';`),patch(['count'],`bar.value=read('count')%100;`)],
    actions:[action('inc',`s.count++;`,['count']),action('toggle','s.active=!s.active;',['active'])],
  };
  if(family==='form')return {
    html:shell('<input aria-label="Value"><output></output><button data-action="save">Save</button><span></span>'),
    state:{input:"''",saved:"''"},setup:`const input=n.querySelector('input'),out=n.querySelector('output'),save=n.querySelector('[data-action=save]'),status=n.querySelector('span');`,
    patches:[patch(['input'],`value(input,read('input'));text(out,read('input').length>=${k%5+1}?'valid':'short');save.disabled=read('input').length<${k%5+1};`),patch(['saved'],`text(status,read('saved'));`)],
    actions:[action('edit',`if(!input.value.includes('#'))s.input=input.value;`,['input'],'input','input'),action('save',`s.saved=s.input;`,['saved'])],
  };
  if(family==='crud')return {
    html:shell('<button data-action="add">Add</button><button data-action="edit">Edit</button><button data-action="remove">Remove</button><button data-action="swap">Swap</button><output></output><div data-rows></div>'),
    state:{rows:`Array.from({length:${population}},(_,id)=>({id,label:'Item '+id}))`,next:String(population),selected:'-1'},
    setup:`const list=n.querySelector('[data-rows]'),out=n.querySelector('output'),cache=new Map();`,
    patches:[patch(['rows','selected'],`rowsPatch(list,read('rows'),read('selected'),cache,id=>actSelect(id));`),patch(['rows'],`text(out,read('rows').length);`)],
    actions:[action('add',`s.rows.push({id:s.next++,label:'${label} '+s.next});`,['rows']),action('edit',`if(s.rows.length)s.rows[0].label+='!';`,['rows']),action('remove',`s.rows.shift();`,['rows']),action('swap',`if(s.rows.length>1){const t=s.rows[0];s.rows[0]=s.rows[s.rows.length-1];s.rows[s.rows.length-1]=t}`,['rows'])],
    extra:[{name:'actSelect',args:'id',body:'s.selected=id;',writes:['selected']}],
  };
  if(family==='board')return {
    html:shell('<button data-action="step">Move</button><button data-action="reset">Reset</button><output></output><div data-board style="display:grid;grid-template-columns:repeat(8,12px)"></div>'),
    state:{position:'0',moves:'0'},
    setup:`const out=n.querySelector('output'),board=n.querySelector('[data-board]');const cells=Array.from({length:64},(_,i)=>{const c=document.createElement('span');c.textContent='·';board.append(c);return c});let old=-1;`,
    patches:[patch(['position'],`const p=read('position');if(old!==p){if(old>=0)cells[old].textContent='·';cells[p].textContent='X';old=p}`),patch(['moves'],`text(out,read('moves')*${k%3+1});`)],
    actions:[action('step',`s.position=(s.position+${k%7+1})%64;s.moves++;`,['position','moves']),action('reset','s.position=0;s.moves=0;',['position','moves'])],
  };
  if(family==='route')return {
    html:shell('<button data-action="load">Load</button><button data-action="bad">Bad body</button><button data-action="invalid">Invalid JSON</button><button data-action="missing">Missing</button><button data-action="slow">Slow</button><button data-action="leave">Leave</button><output></output><span></span>'),
    state:{status:"'idle'",title:"''"},
    setup:`const out=n.querySelector('output'),detail=n.querySelector('span');let controller=null,generation=0;cleanup=()=>{generation++;controller?.abort()};`,
    patches:[patch(['status'],`text(out,read('status'));`),patch(['title'],`text(detail,read('title'));`)],
    actions:[...['load','bad','invalid','missing','slow'].map(name=>action(name,`start('${name}');`,[])),action('leave',`generation++;controller?.abort();s.status='left';s.title='';location.hash='away';`,['status','title'])],
    extra:[{name:'complete',args:'result,token',body:`if(token!==generation)return;s.status=result.error||'ready';s.title=result.data?result.data.title:'';`,writes:['status','title']}],
    tail:`function start(kind){controller?.abort();controller=new AbortController();const token=++generation;location.hash='feature-'+n.dataset.feature;request('/api/'+kind+'?feature='+n.dataset.feature,controller.signal).then(result=>complete(result,token),error=>enter(()=>{throw error}));}`,
  };
  throw new Error(family);
}
function feature(family,mode,i,diverse,population) {
 const p=spec(family,i,diverse,population);
 const signals=mode==='signals';
 const read=body=>signals?body:body.replace(/read\('([a-z]+)'\)/g,(_,key)=>`s.${key}`);
 const patchBodies=p.patches.map(x=>read(x.body));
 const matching=keys=>p.patches.map((p,i)=>p.deps.some(d=>keys.includes(d))?i:-1).filter(i=>i>=0);
 function updates(keys){
  if(!keys.length)return '';
  if(mode==='scan')return 'dirty=true;';
  if(mode==='signals')return `notify(${JSON.stringify(keys)});`;
  if(mode==='indexed')return `dispatch(consumers,${JSON.stringify(keys)});`;
  if(mode==='vanilla')return matching(keys).map(i=>`{${patchBodies[i]}}`).join('');
  return matching(keys).map(i=>`p${i}();`).join('');
 }
 const definitions=patchBodies.map((body,i)=>`function p${i}(){${body}}`).join('\n');
 let routing='';
 if(signals)routing=`const [read,notify,observe]=graph(s);`;
 if(mode==='indexed'){
  const fields=[...new Set(p.patches.flatMap(x=>x.deps))];
  routing=`const consumers={${fields.map(key=>`${key}:[${matching([key]).map(i=>`p${i}`).join(',')}]`).join(',')}};`;
 }
 const methods=[...p.actions.map(a=>({...a,name:`a_${a.name}`,args:'event'})),...(p.extra||[])].map(a=>`function ${a.name}(${a.args}){if(!live)return;enter(()=>{${a.body}${updates(a.writes)}})}`).join('\n');
 const listeners=p.actions.map(a=>`n.querySelector(${JSON.stringify(a.target==='input'?'input':`[data-action=${a.target}]`)}).addEventListener('${a.event}',a_${a.name});`).join('\n');
 const mountPatches=p.patches.map((_,i)=>signals?`observe(p${i});`:`p${i}();`).join('');
 return `{
 const n=mount(${JSON.stringify(p.html)}),s={${Object.entries(p.state).map(([k,v])=>`${k}:${v}`).join(',')}};let live=true,cleanup=()=>{};
 ${p.setup}${routing}${definitions}${methods}${p.tail||''}
 ${listeners}
 const dispose=()=>{if(!live)return;live=false;scopes.delete(dispose);cleanup();${mode==='scan'?p.patches.map((_,i)=>`scans.delete(p${i});`).join(''):''}${family==='fanout'?'fan.delete(a_inc);':''}n.remove()};
 scopes.add(dispose);n.querySelector('[data-action=dispose]').onclick=()=>enter(dispose);
 ${mode==='scan'?p.patches.map((_,i)=>`scans.add(p${i});`).join(''):''}
 ${family==='fanout'?'fan.add(a_inc);':''}
 ${mountPatches}
 }`;
}
export function generate(family,mode,count,diverse=false,population=20){
 if(!families.includes(family)||!modes.includes(mode))throw new Error('unknown candidate');
 let source=common+(family==='route'?network:'')+(family==='crud'?rows:'');
 if(mode==='scan'){
  source='let running=false,dirty=false;const scans=new Set();'+source.replace('if(dead)return;let ok=false;try{f();ok=true}', 'if(dead)return;if(running){f();return}let ok=false;running=true;try{f();if(dirty){dirty=false;for(const patch of scans)patch()}ok=true}').replace('finally{if(!ok)', 'finally{running=false;if(!ok)');
 }
 if(mode==='indexed')source+=`function dispatch(consumers,keys){const pending=new Set();for(const key of keys)for(const f of consumers[key]||[])pending.add(f);for(const f of pending)f()}`;
 if(mode==='signals')source+=`function graph(s){let observer=null;const subscriptions=new Map();function read(key){if(observer){let set=subscriptions.get(key);if(!set)subscriptions.set(key,set=new Set());set.add(observer);observer.deps.add(set)}return s[key]}function notify(keys){const pending=new Set();for(const k of keys)for(const f of subscriptions.get(k)||[])pending.add(f);for(const f of pending)f()}function observe(f){const run=()=>{for(const set of run.deps)set.delete(run);run.deps.clear();const old=observer;observer=run;try{f()}finally{observer=old}};run.deps=new Set();run()}return [read,notify,observe]}`;
 if(family==='fanout')source+=`const fan=new Set();const all=document.createElement('button');all.dataset.action='all';all.textContent='All';root.append(all);all.onclick=()=>enter(()=>{for(const f of fan)f()});`;
 // Repeated components share a factory. Distinct shapes get separate factories;
 // expanded deliberately duplicates even identical factories to price expansion.
 if(!diverse&&mode!=='expanded'){
  const body=feature(family,mode,0,false,population);
  // Replace the feature attribute via a parameter, without interpolating HTML.
  source+=`function instance(index)${body.replace('const n=mount(', 'const n=mount(').replace('let live=true',"n.dataset.feature=index;let live=true")};enter(()=>{for(let i=0;i<${count};i++)instance(i)});`;
 }else source+=`enter(()=>{${Array.from({length:count},(_,i)=>feature(family,mode,i,diverse,population)).join('\n')}});`;
 return source;
}
