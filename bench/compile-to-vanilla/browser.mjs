import {createServer} from 'node:http';
import {readFileSync,writeFileSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {launch} from '../ui/lib/cdp.mjs';
const here=new URL('.',import.meta.url), sizes=JSON.parse(readFileSync(new URL('results/sizes.json',here)));
const verifyOnly=process.argv.includes('--verify');
const chrome=process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const server=createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost');
 const headers={'Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'};
 if(url.pathname.startsWith('/api/')){
  const kind=url.pathname.slice(5);
  const send=()=>{res.writeHead(kind==='missing'?404:200,{'Content-Type':'application/json',...headers});res.end(kind==='bad'?'{}':kind==='invalid'?'{':JSON.stringify({title:'Article '+url.searchParams.get('feature'),count:7}))};
  if(kind==='slow')setTimeout(send,100);else send();return;
 }
 const name=url.pathname.slice(1);
 if(name.endsWith('.js')&&/^[a-z0-9-]+\.js$/.test(name)&&existsSync(new URL('out/'+name,here))){res.writeHead(200,{'Content-Type':'text/javascript',...headers});res.end(readFileSync(new URL('out/'+name,here)));return}
 if(name.endsWith('.html')){res.writeHead(200,{'Content-Type':'text/html',...headers});res.end(`<!doctype html><meta charset="utf-8"><div id="app"></div><script type="module" src="/${name.replace('.html','.js')}"></script>`);return}
 res.writeHead(404);res.end();
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await launch({chrome}),origin=`http://127.0.0.1:${server.address().port}`;
const errors=[];
const off=browser.on(msg=>{if(msg.method==='Runtime.exceptionThrown')errors.push(msg.params.exceptionDetails.exception?.description||msg.params.exceptionDetails.text)});
// The oracle asserts concrete DOM behavior, not emitted function names.
function check(family,count,varied,population){
 const assert=(v,m)=>{if(!v)throw new Error(m)};
 const features=[...document.querySelectorAll('section')];assert(features.length===count,'mount count');
 const samples=count===1?[features[0]]:[features[0],features.at(-1)];
 for(const n of samples){
  const i=Number(n.dataset.feature),k=varied?i:0,click=name=>n.querySelector('[data-action='+name+']').click();
  const output=()=>n.querySelector('output').textContent;
  if(family==='dashboard'||family==='fanout'){
   click('inc');assert(output()===String(k%7+1+(k%2?1:0)),'increment');
   click('toggle');assert(n.className==='','toggle class');assert(output()===String(k%7+1),'toggle derived');
  }else if(family==='form'){
   const input=n.querySelector('input');input.value='accepted';input.dispatchEvent(new Event('input',{bubbles:true}));assert(output()==='valid','validation');
   input.value='#rejected';input.dispatchEvent(new Event('input',{bubbles:true}));assert(input.value==='accepted','controlled rejection');
   click('save');assert(n.querySelector('span').textContent==='accepted','save');
  }else if(family==='board'){
   click('step');assert(n.querySelector('[data-board]').children[k%7+1].textContent==='X','board move');
   assert(output()===String(k%3+1),'move count');click('reset');assert(output()==='0','reset');
  }else if(family==='crud'){
   const list=n.querySelector('[data-rows]'),first=list.firstChild,last=list.lastChild;
   click('swap');assert(list.firstChild===last&&list.lastChild===first,'key identity on swap');
   click('edit');assert(list.firstChild.textContent===`Item ${population-1}!`,'edit');
   list.firstChild.click();assert(list.firstChild.className==='selected','selection');
   click('remove');assert(!last.isConnected,'remove');click('add');assert(list.children.length===population,'add count');
  }
 }
 if(family==='fanout'){
  document.querySelector('[data-action=all]').click();
  assert(features[0].querySelector('output').textContent==='2','fanout first');
  if(count>2){const k=varied?1:0;assert(features[1].querySelector('output').textContent===String(k%7+1+(k%2?1:0)),'fanout untouched instance')}
 }
 const stale=samples[0].querySelector('button'),before=samples[0].textContent;
 samples[0].querySelector('[data-action=dispose]').click();stale.click();
 assert(samples[0].textContent===before,'stale listener after disposal');
 assert(document.querySelectorAll('section').length===count-1,'dispose');
 return document.getElementById('app').innerHTML;
}
async function checkRoute(count){
 const assert=(v,m)=>{if(!v)throw new Error(m)};
 const nodes=[...document.querySelectorAll('section')];assert(nodes.length===count,'route mounts');
 const n=nodes.at(-1),click=name=>n.querySelector('[data-action='+name+']').click(),out=()=>n.querySelector('output').textContent;
 const until=async expected=>{const start=performance.now();while(out()!==expected){if(performance.now()-start>3000)throw new Error('route timeout '+expected+' got '+out());await new Promise(r=>setTimeout(r,2))}};
 click('load');await until('ready');assert(n.querySelector('span').textContent==='Article '+(count-1),'decode');assert(location.hash==='#feature-'+(count-1),'route');
 click('bad');await until('BadBody');click('invalid');await until('BadJson');click('missing');await until('Http 404');
 click('slow');click('leave');await new Promise(r=>setTimeout(r,150));assert(out()==='left'&&n.querySelector('span').textContent==='','stale completion');
 click('slow');const before=n.textContent;click('dispose');await new Promise(r=>setTimeout(r,150));assert(n.textContent===before&&!n.isConnected,'dispose request');
 return document.getElementById('app').innerHTML;
}
// This is script+one forced layout per batch, not click-to-paint latency.
function time(family,operation,batch){
 const node=document.querySelector('section');
 const action=operation==='all'?document.querySelector('[data-action=all]'):node.querySelector('[data-action='+operation+']');
 const input=node.querySelector('input');
 const run=()=>{for(let i=0;i<batch;i++){if(family==='form'){input.value=i%2?'abcde':'abc';input.dispatchEvent(new Event('input',{bubbles:true}))}else action.click()}document.body.offsetHeight};
 run();run();
 const start=performance.now();run();return performance.now()-start;
}
const verified=[],samples=[];
try{
 if(verifyOnly){
  const oracles=new Map();
  for(const row of sizes.observations){
   const actual=createHash('sha256').update(readFileSync(new URL('out/'+row.name+'.js',here))).digest('hex');if(actual!==row.sha256)throw new Error('stale bundle '+row.name);
   const page=await browser.newPage(origin+'/'+row.name+'.html');
   try{
    const population=row.shape==='population'?row.count:20,count=row.shape==='population'?1:row.count;
    const result=await page.eval(row.family==='route'?`(${checkRoute})(${count})`:`(${check})(${JSON.stringify(row.family)},${count},${row.shape==='varied'},${population})`);
    const key=[row.family,row.shape,row.count].join('-');
    // Attribute serialization can reorder class/value properties; compare text,
    // controls and explicit identities above, not browser-specific HTML order.
    const normalized=await page.eval(`JSON.stringify([...document.querySelectorAll('section')].map(n=>({id:n.dataset.feature,text:n.textContent,cls:n.className,inputs:[...n.querySelectorAll('input')].map(x=>x.value)})))`);
    if(row.mode==='vanilla')oracles.set(key,normalized);else if(normalized!==oracles.get(key))throw new Error('differential mismatch '+row.name);
    verified.push({name:row.name,sha256:row.sha256,dom_sha256:createHash('sha256').update(result).digest('hex')});
   }finally{await page.close()}
   if(verified.length%36===0)console.log(`Verified ${verified.length}/${sizes.observations.length}`);
  }
  if(errors.length)throw new Error(errors.join('\n'));
  writeFileSync(new URL('results/verification.json',here),JSON.stringify({browser:browser.version,node:process.version,generator_sha256:sizes.generator_sha256,verified,errors},null,2)+'\n');
 }else{
  const candidates=sizes.observations.filter(p=>(p.shape==='varied'&&[1,64].includes(p.count))||p.shape==='population');
  const order=['vanilla','lexical','indexed','signals','scan','expanded'];
  for(let round=0;round<9;round++){
   // Rotate candidate order across rounds; preserve all observations, no retry trimming.
   const sorted=candidates.toSorted((a,b)=>((order.indexOf(a.mode)+round)%6)-((order.indexOf(b.mode)+round)%6)||a.name.localeCompare(b.name));
   for(const row of sorted){
    const page=await browser.newPage(origin+'/'+row.name+'.html');
    try{
     const operations={dashboard:['inc'],fanout:['inc','all'],form:['edit'],board:['step'],route:['leave'],crud:['edit','swap']}[row.family];
     for(const operation of operations){
      const batch=row.family==='crud'?10:100;
      const ms=await page.eval(`(${time})(${JSON.stringify(row.family)},${JSON.stringify(operation)},${batch})`);
      samples.push({name:row.name,family:row.family,shape:row.shape,mode:row.mode,count:row.count,round,operation,batch,ms});
     }
    }finally{await page.close()}
   }
   console.log(`Timing round ${round+1}/9 (${samples.length} samples)`);
  }
  if(errors.length)throw new Error(errors.join('\n'));
  writeFileSync(new URL('results/timing.json',here),JSON.stringify({browser:browser.version,node:process.version,generator_sha256:sizes.generator_sha256,protocol:'9 fresh pages/cell, two warm batches then one measured batch; programmatic DOM events plus one layout read; deterministic rotation; no network timed',samples,errors},null,2)+'\n');
 }
}finally{off();await browser.close();await new Promise(r=>server.close(r))}
