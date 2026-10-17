// An orthogonal experiment: preserve the operation that changed an owned array.
// Compare the same mutable model with a generic keyed pass vs exact DOM edits.
import {readFileSync,writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {brotliCompressSync,constants} from 'node:zlib';
import {minify} from 'terser';
import {launch} from '../ui/lib/cdp.mjs';
const here=new URL('.',import.meta.url);
function program(mode,count){
 const prefix=`const root=document.getElementById('app');let dead=false;
 function enter(f){if(dead)return;let ok=false;try{f();ok=true}finally{if(!ok)dead=true}}
 const rows=Array.from({length:${count}},(_,id)=>({id,label:'Item '+id}));
 const nodes=new Map(),list=document.createElement('div'),out=document.createElement('output');root.append(out,list);let next=${count},selected=-1,version=0;
 function make(item){const n=document.createElement('button');n.textContent=item.label;n.dataset.row=item.id;n.onclick=()=>enter(()=>select(item.id));nodes.set(item.id,n);return n}
 function select(id){${mode==='delta'?"if(nodes.has(selected))nodes.get(selected).className='';selected=id;if(nodes.has(id))nodes.get(id).className='selected';":"selected=id;patch();"}}
 function patch(){const keep=new Set(rows.map(r=>r.id));for(const [id,n] of nodes)if(!keep.has(id)){n.remove();nodes.delete(id)}let cursor=list.firstChild;for(const r of rows){let n=nodes.get(r.id);if(!n)n=make(r);if(n.textContent!==r.label)n.textContent=r.label;n.className=r.id===selected?'selected':'';if(n!==cursor)list.insertBefore(n,cursor);cursor=n.nextSibling}out.textContent=rows.length}
 ${mode==='delta'?"for(const item of rows)list.append(make(item));out.textContent=rows.length;":"patch();"}
 function button(name,f){const b=document.createElement('button');b.dataset.action=name;b.textContent=name;b.onclick=()=>enter(f);root.prepend(b)}
 `;
 const edit=`const r=rows[0];r.label='Edited '+(++version);`+(mode==='delta'?`nodes.get(r.id).textContent=r.label;`:'patch();');
 const swap=`const a=rows[0],b=rows[rows.length-1];rows[0]=b;rows[rows.length-1]=a;`+(mode==='delta'?`list.insertBefore(nodes.get(b.id),nodes.get(a.id));list.append(nodes.get(a.id));`:'patch();');
 const append=`const r={id:next++,label:'Added'};rows.push(r);`+(mode==='delta'?`list.append(make(r));out.textContent=rows.length;`:'patch();');
 const remove=`const r=rows.pop();`+(mode==='delta'?`nodes.get(r.id).remove();nodes.delete(r.id);out.textContent=rows.length;`:'patch();');
 return prefix+`button('edit',()=>{${edit}});button('swap',()=>{${swap}});button('append',()=>{${append}});button('remove',()=>{if(rows.length>1){${remove}}});`;
}
const variants=[];
for(const count of [100,1000,10000])for(const mode of ['reconcile','delta']){
 const {code}=await minify(program(mode,count),{module:true,compress:{passes:2},mangle:true});
 const name=`edits-${mode}-${count}`;writeFileSync(new URL('out/'+name+'.js',here),code);
 variants.push({name,mode,count,raw:Buffer.byteLength(code),brotli:brotliCompressSync(code,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:Buffer.byteLength(code)}}).length,sha256:createHash('sha256').update(code).digest('hex')});
}
function measure(count){
 const assert=(x,m)=>{if(!x)throw new Error(m)},click=name=>document.querySelector('[data-action='+name+']').click();
 const list=document.querySelector('#app>div'),first=list.firstChild,last=list.lastChild;
 click('swap');assert(list.firstChild===last&&list.lastChild===first,'swap identity');click('swap');
 click('edit');assert(first.textContent==='Edited 1','edit');last.click();assert(last.className==='selected','selection');first.click();assert(first.className==='selected'&&last.className==='','deselect');
 click('append');assert(list.children.length===count+1,'append');click('remove');assert(list.children.length===count,'remove');
 const batches={edit:()=>{for(let i=0;i<30;i++)click('edit')},swap:()=>{for(let i=0;i<30;i++)click('swap')},select:()=>{for(let i=0;i<30;i++)(i%2?first:last).click()},appendRemove:()=>{for(let i=0;i<30;i++){click('append');click('remove')}}};
 const result={};for(const [key,run] of Object.entries(batches)){run();run();document.body.offsetHeight;const start=performance.now();run();document.body.offsetHeight;result[key]=performance.now()-start}return result;
}
const server=createServer((req,res)=>{const name=req.url.slice(1);res.setHeader('Cross-Origin-Opener-Policy','same-origin');res.setHeader('Cross-Origin-Embedder-Policy','require-corp');if(variants.some(v=>name===v.name+'.js')){res.setHeader('Content-Type','text/javascript');res.end(readFileSync(new URL('out/'+name,here)))}else if(variants.some(v=>name===v.name)){res.end(`<!doctype html><div id="app"></div><script type="module" src="/${name}.js"></script>`)}else{res.statusCode=404;res.end()}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const browser=await launch({chrome:process.env.CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}),samples=[],errors=[];
const off=browser.on(m=>{if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails)});
try{
 for(let round=0;round<9;round++)for(const v of round%2?variants.toReversed():variants){const page=await browser.newPage(`http://127.0.0.1:${server.address().port}/${v.name}`);try{samples.push({...v,round,batch:30,ms:await page.eval(`(${measure})(${v.count})`)})}finally{await page.close()}}
 if(errors.length)throw new Error(JSON.stringify(errors));
 writeFileSync(new URL('results/edits.json',here),JSON.stringify({browser:browser.version,node:process.version,variants,samples,errors},null,2)+'\n');console.log('Array edit experiment: 54 verified pages');
}finally{off();await browser.close();await new Promise(r=>server.close(r))}
