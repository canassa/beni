// Profile the emitted ball machine in Chrome. Timing and profiling are separate runs.
import {createServer} from 'node:http';
import {readFileSync,writeFileSync,mkdirSync,existsSync,statSync} from 'node:fs';
import {resolve,join,extname,sep} from 'node:path';
import {cpus,arch,platform,totalmem,loadavg} from 'node:os';
import {gzipSync} from 'node:zlib';
import {launch,officialFlags,sleep,traced} from '../ui/lib/cdp.mjs';
import {median,quantile} from '../ui/lib/trace.mjs';
const arg=(n,d)=>process.argv.find(x=>x.startsWith(`--${n}=`))?.slice(n.length+3)??d;
const root=resolve(arg('build','zig-out/bench/ball-machine'));
const out=resolve(arg('out','zig-out/bench/ball-machine/results'));
const label=arg('label','');
const mode=arg('mode','timing'),seconds=Number(arg('seconds','15')),warmup=Number(arg('warmup','5')),repeats=Number(arg('repeats','3'));
const width=Number(arg('width','1280')),height=Number(arg('height','800')),dpr=Number(arg('dpr','1'));
const atOnce=Number(arg('at-once','4')),batch=Number(arg('batch','3')),throttle=Number(arg('throttle','1'));
const names=arg('variants','dev,release,no-filters,no-animations,svg-hidden').split(',');
const subjects={
 dev:{dir:'dev'},release:{dir:'release'},gradient:{dir:'gradient'},
 'no-filters':{dir:'dev',css:'svg, svg * { filter:none !important; }'},
 'no-animations':{dir:'dev',css:'.air,.flow { animation:none !important; }'},
 'no-fx':{dir:'dev',css:'svg,svg * {filter:none!important} .air,.flow {animation:none!important}'},
 'svg-hidden':{dir:'dev',css:'.machine svg {display:none!important}'},
 'no-dynamic-filters':{dir:'dev',css:'svg [filter="url(#glow)"],svg [filter="url(#ballShadow)"] {filter:none!important}'},
 'no-glow':{dir:'dev',css:'svg [filter="url(#glow)"] {filter:none!important}'},
 'no-static-shadows':{dir:'dev',css:'svg [filter="url(#shadow)"],svg [filter="url(#rodShadow)"] {filter:none!important}'},
 'no-ball-shadows':{dir:'dev',css:'svg [filter="url(#ballShadow)"] {filter:none!important}'},
 'small-glow':{dir:'dev',js:`document.querySelector('#glow feGaussianBlur').setAttribute('stdDeviation','1')`},
 'cached-cabinet':{dir:'dev',js:`(async()=>{
  const svg=document.querySelector('svg'),cabinet=svg.querySelector('.cabinet');
  const data='<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 0 412 560">'+svg.querySelector('defs').outerHTML+cabinet.outerHTML+'</svg>';
  const url='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(data);
  const probe=new Image();probe.src=url;await probe.decode();
  const image=document.createElementNS('http://www.w3.org/2000/svg','image');
  for(const[k,v]of Object.entries({x:-12,y:0,width:412,height:560,href:url}))image.setAttribute(k,String(v));
  image.classList.add('cached-cabinet');cabinet.replaceWith(image);
 })()`},
};
for(const n of names) if(!subjects[n]) throw Error(`unknown variant ${n}`);
mkdirSync(out,{recursive:true});
const types={'.html':'text/html','.mjs':'text/javascript','.js':'text/javascript','.map':'application/json','.css':'text/css'};
const server=createServer((req,res)=>{
 const u=new URL(req.url,'http://localhost');
 const f=resolve(root,'.'+decodeURIComponent(u.pathname)+(u.pathname.endsWith('/')?'index.html':''));
 if(!f.startsWith(root+sep)||!existsSync(f)||!statSync(f).isFile()){res.writeHead(404).end();return;}
 res.writeHead(200,{'Content-Type':types[extname(f)]??'application/octet-stream','Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp','Cache-Control':'no-store'});
 res.end(readFileSync(f));
});
await new Promise(done=>server.listen(0,'127.0.0.1',done));
const origin=`http://127.0.0.1:${server.address().port}`;
// The shared table harness defaults to software rendering. This benchmark needs the GPU.
for(const flag of ['--disable-gpu',...(arg('headful','false')==='true'?['--headless=new']:[])]) {const i=officialFlags.indexOf(flag);if(i>=0) officialFlags.splice(i,1);}
const chrome=arg('chrome','/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
const browser=await launch({chrome});
const system=await browser.send('SystemInfo.getInfo');
const result={started:new Date().toISOString(),mode,seconds,warmup,repeats,atOnce,batch,throttle,chrome:browser.version,node:process.version,machine:{cpu:cpus()[0].model,arch:arch(),platform:platform(),cores:cpus().length,ramBytes:totalmem(),load:loadavg()},gpu:system.gpu,flags:officialFlags,build:JSON.parse(readFileSync(join(root,'built.json'),'utf8')),runs:[]};
const metricMap=r=>Object.fromEntries(r.metrics.map(x=>[x.name,x.value]));
const setup=`(() => {
 const b=globalThis.__ballBench={active:false,intervals:[],longTasks:[],counts:[]};
 let last=null;
 const frame=(t)=>{if(b.active&&last!==null)b.intervals.push(t-last);last=t;requestAnimationFrame(frame)};
 requestAnimationFrame(frame);
 b.observer=new PerformanceObserver(list=>{if(b.active)for(const e of list.getEntries())b.longTasks.push(e.duration)});
 b.observer.observe({type:'longtask',buffered:false});
 b.timer=setInterval(()=>{if(b.active)b.counts.push(document.querySelectorAll('circle[r="7.5"]').length)},500);
 return {isolated:crossOriginIsolated,viewport:[innerWidth,innerHeight,devicePixelRatio]};
})()`;
function profileSummary(profile){
 const nodes=new Map(profile.nodes.map(n=>[n.id,n]));const parent=new Map();
 for(const n of profile.nodes)for(const id of n.children??[])parent.set(id,n.id);
 const self=new Map(),inclusive=new Map();let busyUs=0,totalUs=0;
 for(let i=0;i<profile.samples.length;i++){
  const id=profile.samples[i],us=profile.timeDeltas?.[i]??100;totalUs+=us;
  if(nodes.get(id).callFrame.functionName==='(idle)')continue;
  busyUs+=us;self.set(id,(self.get(id)??0)+us);
  const seen=new Set();for(let p=id;p!==undefined;p=parent.get(p)){
   const f=nodes.get(p).callFrame;const key=`${f.functionName} ${f.url}:${f.lineNumber+1}`;
   if(!seen.has(key)){inclusive.set(key,(inclusive.get(key)??0)+us);seen.add(key);}
  }
 }
 const frame=f=>({name:f.functionName||'(anonymous)',url:f.url.replace(origin,''),line:f.lineNumber+1,column:f.columnNumber});
 return {busyMs:busyUs/1000,wallMs:totalUs/1000,samples:profile.samples.length,self:[...self].sort((a,b)=>b[1]-a[1]).slice(0,40).map(([id,us])=>({...frame(nodes.get(id).callFrame),ms:us/1000,busyPercent:100*us/busyUs})),inclusive:[...inclusive].sort((a,b)=>b[1]-a[1]).slice(0,50).map(([name,us])=>({name:name.replaceAll(origin,''),ms:us/1000,busyPercent:100*us/busyUs}))};
}
function allocationSummary(profile){
 const rows=[];let bytes=0;const visit=(n,stack=[])=>{const f=n.callFrame;const row={name:f.functionName||'(anonymous)',url:f.url.replace(origin,''),line:f.lineNumber+1,bytes:n.selfSize,stack};if(n.selfSize){rows.push(row);bytes+=n.selfSize;}for(const c of n.children??[])visit(c,[...stack,`${row.name} ${row.url}:${row.line}`]);};
 visit(profile.head);return {sampledBytesEstimate:bytes,mbPerSecond:bytes/1e6/seconds,top:rows.sort((a,b)=>b.bytes-a.bytes).slice(0,35)};
}
function traceSummary(events){
 const thread=events.find(e=>e.name==='thread_name'&&e.args.name==='CrRendererMain');
 const main=thread?events.filter(e=>e.pid===thread.pid&&e.tid===thread.tid):events;
 const names=['FireAnimationFrame','RunMicrotasks','UpdateLayoutTree','Layout','PrePaint','Paint','Layerize','MinorGC','MajorGC','V8.GC_SCAVENGER','V8.GC_MARK_COMPACTOR'];
 return {mainThread:thread?.args.name,events:events.length,stages:Object.fromEntries(names.map(name=>{const es=main.filter(e=>e.name===name&&e.ph==='X');const ms=es.map(e=>e.dur/1000);return [name,{calls:es.length,totalMs:ms.reduce((a,b)=>a+b,0),medianMs:median(ms),p95Ms:quantile(ms,.95)}]}))};
}
try{
 for(let rep=0;rep<repeats;rep++){
  // Alternate order so heat/load changes do not always favour the same build.
  for(const name of (rep%2?[...names].reverse():names)){
   const errors=[];
   const subject=subjects[name];const page=await browser.newPage(`${origin}/${subject.dir}/`);
   const offErrors=browser.on(m=>{if(m.sessionId===page.sessionId&&m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails);});
   await page.waitFor('document.querySelector("#at-once")!==null');
   await page.send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:dpr,mobile:false});
   if(throttle!==1)await page.send('Emulation.setCPUThrottlingRate',{rate:throttle});
   await page.eval(`(() => { const css=document.createElement('style');css.textContent=${JSON.stringify(subject.css??'')};document.head.append(css);for(const [id,value]of [['at-once',${atOnce}],['per-batch',${batch}]]){const e=document.getElementById(id);e.value=String(value);e.dispatchEvent(new Event('input',{bubbles:true}));}})()`);
   if(arg('headful','false')==='true')await page.send('Page.bringToFront');
   if(subject.js)await page.eval(subject.js);
   const environment=await page.eval(setup);await page.send('Performance.enable');
   await sleep(warmup*1000);await page.send('HeapProfiler.collectGarbage');await sleep(200);
   const before=metricMap(await page.send('Performance.getMetrics'));
   if(mode==='cpu'){await page.send('Profiler.enable');await page.send('Profiler.setSamplingInterval',{interval:100});await page.send('Profiler.start');}
   if(mode==='alloc')await page.send('HeapProfiler.startSampling',{samplingInterval:32768,includeObjectsCollectedByMajorGC:true,includeObjectsCollectedByMinorGC:true});
   await page.eval('__ballBench.active=true');
   const start=performance.now();let trace;
   if(mode==='trace')trace=await traced(page,['devtools.timeline','v8.gc','blink.user_timing'],()=>sleep(seconds*1000));else await sleep(seconds*1000);
   const wallMs=performance.now()-start;
   const data=await page.eval('(() => {__ballBench.active=false;return {intervals:__ballBench.intervals,longTasks:__ballBench.longTasks,counts:__ballBench.counts,domNodes:document.querySelectorAll("*").length,tally:document.querySelector(".tally").textContent}})()');
   const after=metricMap(await page.send('Performance.getMetrics'));
   const id=`${label?label+'-':''}${mode}-${name}-${atOnce}-${batch}-${rep}`;
   if(errors.length)throw Error(JSON.stringify(errors));
   const row={name,rep,wallMs,frameIntervalsMs:data.intervals,ballSamples:data.counts,metricsBefore:before,metricsAfter:after,frames:data.intervals.length,fps:1000*data.intervals.length/wallMs,intervalMs:{median:median(data.intervals),p95:quantile(data.intervals,.95),p99:quantile(data.intervals,.99),over25:data.intervals.filter(x=>x>25).length},ballCount:{median:median(data.counts),min:Math.min(...data.counts),max:Math.max(...data.counts)},domNodes:data.domNodes,tally:data.tally,longTasks:data.longTasks,environment,metrics:{}};
   for(const key of ['TaskDuration','ScriptDuration','LayoutDuration','RecalcStyleDuration','LayoutCount','RecalcStyleCount'])row.metrics[key]=after[key]-before[key];
   row.mainMsPerFrame=1000*row.metrics.TaskDuration/row.frames;row.scriptMsPerFrame=1000*row.metrics.ScriptDuration/row.frames;
   row.heapBefore=before.JSHeapUsedSize;row.heapAfter=after.JSHeapUsedSize;
   if(mode==='cpu'){const {profile}=await page.send('Profiler.stop');writeFileSync(join(out,`${id}.cpuprofile.gz`),gzipSync(JSON.stringify(profile)));row.profile=profileSummary(profile);}
   if(mode==='alloc'){const {profile}=await page.send('HeapProfiler.stopSampling');writeFileSync(join(out,`${id}.heapprofile.gz`),gzipSync(JSON.stringify(profile)));row.allocation=allocationSummary(profile);}
   if(trace){writeFileSync(join(out,`${id}.trace.json.gz`),gzipSync(JSON.stringify({traceEvents:trace})));row.trace=traceSummary(trace);}
   await page.send('HeapProfiler.collectGarbage');row.retainedHeap=metricMap(await page.send('Performance.getMetrics')).JSHeapUsedSize;
   if(arg('screenshots','false')==='true'){const {data:png}=await page.send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});writeFileSync(join(out,`${id}.png`),Buffer.from(png,'base64'));}
   result.runs.push(row);writeFileSync(join(out,`${label?label+'-':''}${mode}-${atOnce}-${batch}.json`),JSON.stringify(result,null,2)+'\n');
   console.log(JSON.stringify({mode,name,rep,fps:row.fps,mainMsPerFrame:row.mainMsPerFrame,scriptMsPerFrame:row.scriptMsPerFrame,intervalMs:row.intervalMs,balls:row.ballCount,allocation:row.allocation?.mbPerSecond,hot:row.profile?.self.slice(0,8),trace:row.trace}));
   offErrors();await page.close();
  }
 }
}finally{server.close();await browser.close();}
