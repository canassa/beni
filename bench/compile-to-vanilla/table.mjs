// Reuse research 29's actual init, click, trace and postcondition routines.
// This is a rate-1 subset, not a new official JFB result or a parity claim.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {minify} from 'terser';
import {createHash} from 'node:crypto';
import {brotliCompressSync,constants} from 'node:zlib';
import {cpus} from 'node:os';
import {launch,sleep,traced} from '../ui/lib/cdp.mjs';
import {serve,root} from '../ui/lib/serve.mjs';
import {benchmarks} from '../ui/lib/benchmarks.mjs';
import {analyse,categories} from '../ui/lib/trace.mjs';
const here=new URL('.',import.meta.url);
const hash=b=>createHash('sha256').update(b).digest('hex');
const {code}=await minify(readFileSync(new URL('table.js',here),'utf8'),{module:true,compress:{passes:2},mangle:true});
mkdirSync(root+'/out/compile-to-vanilla',{recursive:true});
writeFileSync(root+'/out/compile-to-vanilla/table.js',code);
const subjects=[{name:'candidate',kind:'script',body:'static',src:'/out/compile-to-vanilla/table.js',module:true},{name:'vanillajs',kind:'script',body:'static',src:'/out/jfb/Main.js'},{name:'solid2',kind:'solid',entry:'bench'}];
const {server,origin}=await serve(subjects),browser=await launch({chrome:process.env.CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const samples=[],errors=[];
const off=browser.on(m=>{if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails)});
const chosen=benchmarks.filter(b=>['01_run1k','03_update10th1k_x16','05_swap1k','06_remove-one-1k'].includes(b.id));
try{
 for(const b of chosen)for(let round=0;round<9;round++)for(let k=0;k<subjects.length;k++){
  const subject=subjects[(k+round)%subjects.length],page=await browser.newPage(origin+'/s/'+subject.name+'/');
  try{
   await b.init(page);await sleep(100);await page.eval('window.gc && window.gc()');const box=await page.locate(b.target);await sleep(50);
   const events=await traced(page,categories,async()=>{await page.press(box);await sleep(500)});
   if(!await page.eval(b.done))throw new Error(subject.name+' '+b.id+' postcondition');
   samples.push({subject:subject.name,operation:b.id,round,...analyse(events)});
  }finally{await page.close()}
  if(k===subjects.length-1)console.log(`Table ${b.id} round ${round+1}/9`);
 }
 if(errors.length)throw new Error(JSON.stringify(errors));
 const files={candidate:Buffer.from(code),vanillajs:readFileSync(root+'/out/jfb/Main.js'),solid2:readFileSync(root+'/out/solid2/bench.js')};
 const artifacts=Object.fromEntries(Object.entries(files).map(([k,b])=>[k,{sha256:hash(b),raw:b.length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length}]));
 writeFileSync(new URL('results/table.json',here),JSON.stringify({browser:browser.version,node:process.version,cpu:cpus()[0].model,protocol:'research 29 init/trace/postconditions; rate 1; 9 fresh pages/cell; rotated order; no retries',artifacts,samples,errors},null,2)+'\n');
}finally{off();await browser.close();await new Promise(r=>server.close(r))}
