// Fresh Chrome pages, rotated platforms, scripted API from the corpus.
// Run measure.mjs first. Timing copies have no dispatch/group instrumentation.
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { cpus, loadavg } from 'node:os';
import { launch, traced } from '../ui/lib/cdp.mjs';
const repo = resolve(import.meta.dirname, '../..');
const arg = (n,d) => process.argv.find(s=>s.startsWith(`--${n}=`))?.slice(n.length+3) ?? d;
const median=values=>{const a=values.toSorted((x,y)=>x-y);const n=a.length;return n===0?null:n%2?a[(n-1)/2]:(a[n/2-1]+a[n/2])/2;};
const summary=arg('summarise','');
if(summary){
  const result=JSON.parse(readFileSync(summary,'utf8'));
  for(const row of result.rows)for(const subject of row.subjects){
    subject.untracedMedian=median(subject.raw.filter(r=>!r.tracing).map(r=>r.ms));
    subject.tracedMedian=median(subject.raw.filter(r=>r.tracing).map(r=>r.scriptMs));
  }
  console.log(JSON.stringify(result,null,2));process.exit(0);
}
const work = resolve(arg('work',join(repo,'zig-out/conduit-measured')));
const samples = Number(arg('samples', '15'));
const compileTrace=process.argv.includes('--compile-trace');
const allocations=process.argv.includes('--allocations');
const profiles = arg('profiles', '');
if (profiles) mkdirSync(profiles, {recursive:true});
const driver = readFileSync(join(repo,'tests/browser/driver.mjs'),'utf8');
const pageCode = driver.slice(driver.indexOf('function prelude()'), driver.indexOf('// ---------------------------------------------------------------------------',driver.indexOf('function prelude()')));
function parse(line) {
  const [command, selector] = line.split(/\s+/);
  const s = {command, selector, line};
  if (command==='url') s.text=JSON.parse(line.slice(4));
  if (command==='store') {
    const m=line.match(/^store (local|session) ("(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*")$/);
    if (!m) throw new Error(line);
    s.key=JSON.parse(m[2]);s.value=JSON.parse(m[3]);
  }
  if (command==='input') s.text=JSON.parse(line.slice(command.length+selector.length+2));
  if (command==='respond') {
    const m=line.match(/^respond (\d+) (\d+) ("(?:[^"\\]|\\.)*")(.*)$/);
    if (!m) throw new Error(line);
    s.n=Number(m[1]);s.status=Number(m[2]);s.body=JSON.parse(m[3]);s.headers=[];
    let rest=m[4].trim();
    while (rest) {
      const h=rest.match(/^([^ :]+): ("(?:[^"\\]|\\.)*")\s*/);
      if (!h) throw new Error(line);
      s.headers.push([h[1],JSON.parse(h[2])]);rest=rest.slice(h[0].length);
    }
  }
  return s;
}
const scripts = Object.fromEntries(['Reader','Editor'].map(n=>[n,readFileSync(join(repo,`tests/corpus/browser/direct/Conduit${n}/_expected.steps`),'utf8').split('\n').filter(l=>l && !l.startsWith('#')).map(parse)]));
const ops = [
  {name:'feed tab', script:'Reader', target:'click .feed-toggle>ul>li:nth-child(2)>a', event:'click'},
  {name:'favorite', script:'Reader', target:'click .banner>.container>.article-meta>span>button:nth-child(2)', event:'click'},
  {name:'editor keystroke', script:'Editor', target:'input #title " "', event:'input'}
];
const baseline = arg('baseline', '');
const subjects=['browser-tea-release', ...(baseline ? [baseline] : []), 'browser-direct-release'];
const server=createServer((req,res)=>{
  res.setHeader('Cross-Origin-Opener-Policy','same-origin');res.setHeader('Cross-Origin-Embedder-Policy','require-corp');
  if (req.url==='/') {res.setHeader('Content-Type','text/html');res.end('<!doctype html><html><body></body></html>');return;}
  const f=resolve(work,'.'+new URL(req.url,'http://localhost').pathname);
  if (!f.startsWith(work+'/') || !existsSync(f)) {res.writeHead(404).end();return;}
  res.setHeader('Content-Type','text/javascript');res.end(readFileSync(f));
});
await new Promise(done=>server.listen(0,'127.0.0.1',done));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await launch({chrome:arg('chrome','/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')});
const results={date:new Date().toISOString(),commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),buildMode:'release',profiling:profiles?{samplingIntervalUs:25,compileTrace,allocations}:null,node:process.version,chrome:browser.version,cpu:cpus()[0].model,load:loadavg(),samples,sources:Object.fromEntries(subjects.map(s=>[s,createHash('sha256').update(readFileSync(join(work,s,'_main.mjs'))).digest('hex')])),method:'Fresh page per sample; rotated release platforms; corpus scripted API and virtual clock; real CDP clicks and Input.insertText. Capture to eight microtasks untraced, and trace script union. Setup outside timing; transcript/property checks after. No CSS.',rows:[]};
const call=(fn,arg)=>`__s6Page.${fn}(${arg===undefined?'':JSON.stringify(arg)})`;
function union(events) {
  const start=events.find(e=>e.name==='s6-start');
  const from=start?.ts,to=events.find(e=>e.name==='s6-end')?.ts;
  if(from===undefined || to===undefined)throw new Error('Missing timing marks');
  const ranges=events.filter(e=>e.pid===start.pid && e.tid===start.tid && e.ph==='X' && e.ts+e.dur>=from && e.ts<=to && ['EventDispatch','FunctionCall','RunMicrotasks'].includes(e.name)).map(e=>[Math.max(from,e.ts),Math.min(to,e.ts+e.dur)]).sort((a,b)=>a[0]-b[0]);
  let total=0,hi=-Infinity;
  for(const [lo,end] of ranges){total+=Math.max(0,end-Math.max(lo,hi));hi=Math.max(hi,end);}
  return total/1000;
}
try {
  for (const op of ops) {
    const collected=Object.fromEntries(subjects.map(s=>[s,[]]));
    let oracle=null;
    for (let sample=0;sample<samples;sample++) {
      const shift = sample % subjects.length;
      const order = [...subjects.slice(shift), ...subjects.slice(0, shift)];
      for (const subject of subjects.length > 2 && sample%2 ? order.reverse() : order) {
        for (const tracing of (profiles ? [true] : [false,true])) {
          const page=await browser.newPage(origin+'/');
          try {
            await page.eval(`(()=>{${pageCode}\nglobalThis.__s6Page={prelude,load,step,settle,serialise};comments=false;prelude();})()`);
            const steps=scripts[op.script];const index=steps.findIndex(s=>s.line===op.target);
            if(index<0)throw new Error('Missing timed step');
            let at=0;
            while(['url','store'].includes(steps[at]?.command)) {await page.eval(call('step',steps[at++]));}
            await page.eval(call('load',{url:`${origin}/${subject}/_main.mjs`,runtime:null}));
            await page.eval(call('settle'));
            for(;at<index;at++){const why=await page.eval(call('step',steps[at]));if(why!==null)throw new Error(String(why));await page.eval(call('settle'));}
            const selector=steps[index].selector;
            let point;
            if(op.event==='click')point=await page.locate(`document.querySelector(${JSON.stringify(selector)})`);
            else {
              await page.eval(`(()=>{const el=document.querySelector(${JSON.stringify(selector)});el.focus();el.setSelectionRange(el.value.length,el.value.length);})()`);
            }
            await page.eval(`(()=>{globalThis.__s6Done=false;let start;window.addEventListener(${JSON.stringify(op.event)},()=>{start=performance.now();performance.mark('s6-start');},{capture:true,once:true});window.addEventListener(${JSON.stringify(op.event)},()=>{let n=8;const end=()=>{if(--n)queueMicrotask(end);else{globalThis.__s6Ms=performance.now()-start;performance.mark('s6-end');globalThis.__s6Done=true;}};queueMicrotask(end);},{once:true});})()`);
            const send=async()=>{
              if(op.event==='click')await page.press(point);else await page.send('Input.insertText',{text:'x'});
              await page.waitFor('__s6Done');
            };
            if (profiles) {
              await page.send('Profiler.enable');
              await page.send('Profiler.setSamplingInterval', {interval:25});
              await page.send('Profiler.start');
              if(allocations) await page.send('HeapProfiler.startSampling',{samplingInterval:128,includeObjectsCollectedByMajorGC:true,includeObjectsCollectedByMinorGC:true});
            }
            const trace=tracing?await traced(page,['devtools.timeline','blink.user_timing','v8',...(compileTrace?['v8.compile','disabled-by-default-v8.compile','disabled-by-default-v8.runtime_stats']:[])],send):(await send(),null);
            if (profiles) {
              const {profile}=await page.send('Profiler.stop');
              const heap=allocations?(await page.send('HeapProfiler.stopSampling')).profile:null;
              writeFileSync(join(profiles,`${op.script}-${op.event}-${op.name.replaceAll(' ','_')}-${subject}-${sample}.json.gz`), gzipSync(JSON.stringify({operation:op.name,subject,sample,profile,trace,heap})));
            }
            await page.eval(call('settle'));
            const state=await page.eval(`({body:__s6Page.serialise(false),title:document.title,errors:__beniHarness.errors})`);
            if(state.errors.length)throw new Error(JSON.stringify(state.errors));
            if(oracle===null)oracle=JSON.stringify(state);else if(oracle!==JSON.stringify(state))throw new Error(`${op.name}: platforms disagree after timed event`);
            collected[subject].push({sample,position:order.indexOf(subject),tracing,load:loadavg()[0],ms:await page.eval('__s6Ms'),scriptMs:trace?union(trace):null});
          } finally {await page.close();}
        }
      }
    }
    results.rows.push({operation:op.name,subjects:subjects.map(subject=>({subject,untracedMedian:median(collected[subject].filter(r=>!r.tracing).map(r=>r.ms)),tracedMedian:median(collected[subject].filter(r=>r.tracing).map(r=>r.scriptMs)),raw:collected[subject]}))});
  }
} finally {await browser.close();await new Promise(done=>server.close(done));}
results.finished=new Date().toISOString();
console.log(JSON.stringify(results,null,2));
