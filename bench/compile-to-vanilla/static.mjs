// Research 29's static-heavy page and in-page instrument, at rate 1.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {minify} from 'terser';
import {serve,root} from '../ui/lib/serve.mjs';
import {launch} from '../ui/lib/cdp.mjs';
const here=new URL('.',import.meta.url),source=readFileSync(root+'/apps/micro/p2/static.js','utf8');
const template=source.match(/^TPL.innerHTML = (.*);$/m)[1];
mkdirSync(root+'/out/compile-to-vanilla',{recursive:true});
const artifacts={};
for(const mode of ['vanilla','lexical']){
 const code=`const t0=performance.now(),tpl=document.createElement('template');tpl.innerHTML=${template};const node=tpl.content.firstChild.cloneNode(true),spans=[...node.querySelectorAll('h2 span')];for(const n of spans)n.textContent='0';let tick=0;${mode==='vanilla'?`const counts=Array(50).fill(0);const bump=()=>{const i=tick++%50;spans[i].firstChild.data=++counts[i]};`:`let dead=false;function enter(f){if(dead)return;let ok=false;try{f();ok=true}finally{if(!ok)dead=true}}const handlers=spans.map(n=>{let count=0;return ()=>{n.firstChild.data=++count}});const bump=()=>enter(handlers[tick++%50]);`}node.firstChild.onclick=bump;document.body.append(node);window.__mount=performance.now()-t0;window.__flush=()=>{};`;
 const out=(await minify(code,{module:true,compress:{passes:2},mangle:true})).code;
 writeFileSync(root+'/out/compile-to-vanilla/static-'+mode+'.js',out);artifacts[mode]={sha256:createHash('sha256').update(out).digest('hex'),raw:Buffer.byteLength(out)};
}
artifacts.solid2={sha256:createHash('sha256').update(readFileSync(root+'/out/solid2/static.js')).digest('hex')};
const subjects=[...['vanilla','lexical'].map(mode=>({name:mode,kind:'script',module:true,src:'/out/compile-to-vanilla/static-'+mode+'.js'})),{name:'solid2',kind:'solid',entry:'static'}];
const {server,origin}=await serve(subjects),browser=await launch({chrome:process.env.CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}),samples=[],errors=[];
const off=browser.on(m=>{if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails)});
function measure(){
 const b=document.getElementById('bump'),f=window.__flush;
 const loop=(n,layout)=>{const start=performance.now();for(let i=0;i<n;i++){b.click();f();if(layout)document.body.offsetHeight}return performance.now()-start};
 loop(300,false);const script=[],layout=[];
 for(let i=0;i<10;i++)script.push(loop(100,false));for(let i=0;i<10;i++)layout.push(loop(100,true));
 const values=[...document.querySelectorAll('h2 span')].map(n=>Number(n.textContent));
 if(values.length!==50||values.some(x=>x!==46))throw new Error('static output differs from 2300 round-robin increments');
 return {script,layout,elements:document.querySelector('main').querySelectorAll('*').length,mount:window.__mount};
}
try{
 for(let round=0;round<9;round++)for(let k=0;k<subjects.length;k++){
  const subject=subjects[(round+k)%subjects.length],page=await browser.newPage(origin+'/s/'+subject.name+'/');
  try{await page.waitFor('window.__flush !== undefined');samples.push({subject:subject.name,round,batch:100,...await page.eval(`(${measure})()`)})}finally{await page.close()}
 }
 if(errors.length)throw new Error(JSON.stringify(errors));
 writeFileSync(new URL('results/static.json',here),JSON.stringify({browser:browser.version,node:process.version,artifacts,samples,errors},null,2)+'\n');console.log('Static-heavy page: 27 verified pages');
}finally{off();await browser.close();await new Promise(r=>server.close(r))}
