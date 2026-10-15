// CPU self samples clipped to the real-event marks; source names from the
// measurement-only bundle-map.patch. Ordered removal prices as-served brotli
// without claiming that separately compressed parts add up to a download.
import {readFileSync,writeFileSync,readdirSync,statSync} from 'node:fs';
import {gunzipSync,brotliCompressSync,constants} from 'node:zlib';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
const require=createRequire(import.meta.url);
const acorn=require('../ui/apps/solid1/node_modules/acorn');
const arg=(n,d)=>process.argv.find(s=>s.startsWith(`--${n}=`))?.slice(n.length+3)??d;
const work=resolve(arg('work','zig-out/conduit-measured'));
const profileDir=arg('profiles','zig-out/conduit-profiles-before');
const mapPrefix=arg('maps','zig-out/conduit-map');
const br=s=>brotliCompressSync(Buffer.from(s),{params:{[constants.BROTLI_PARAM_QUALITY]:11}}).length;
const output={method:'As-served release source. CPU self intervals after reconstructing and stably sorting sample timestamps, clipped to s6-start/end marks; no inclusive double counting. Known compilation is the main-thread trace union; native/program gaps are not interpolated. Ordered replacement of source declarators by name=0 stubs without reoptimising unrelated code; remaining compression interactions and stubs are charged to later parts/startup. Peeling is an attribution convention, not executable variants.',subjects:{},profiles:{}};
const maps={};
function walk(n,f,parent=null){if(!n||typeof n!=='object')return;if(n.type)f(n,parent);for(const [k,v] of Object.entries(n))if(!['start','end'].includes(k)){if(Array.isArray(v))v.forEach(x=>walk(x,f,n));else if(v&&typeof v==='object')walk(v,f,n);}}
for(const subject of arg('subjects','browser-tea-release,browser-direct-release').split(',')){
 const platform=subject.includes('direct')?'direct':'tea';
 const source=readFileSync(`${work}/${subject}/_main.mjs`,'utf8');
 const prefix=subject.includes('-start-')?arg('before-maps','zig-out/conduit-map'):mapPrefix;
 const lines=readFileSync(`${prefix}-${platform}.tsv`,'utf8').split('\n').map(l=>l.split('\t'));
 const parts=lines.filter(l=>l[0]==='PART').map(([,a,b,path])=>({start:Buffer.from(source).subarray(0,+a).toString().length,end:Buffer.from(source).subarray(0,+b).toString().length,path}));
 const names=new Map(lines.filter(l=>l[0]==='MAP').map(([,name,module,original])=>[name,{module,original}]));
 const ast=acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'});
 const topDecls=new Set(ast.body.flatMap(n=>n.type==='VariableDeclaration'?n.declarations:[]));
 const decls=[];const functions=[];
 walk(ast,(n)=>{if(n.type==='VariableDeclarator')decls.push(n);if(n.type==='ArrowFunctionExpression'||n.type==='FunctionExpression')functions.push(n);});
 const partAt=n=>parts.find(p=>p.start<=n&&n<p.end);
 const planName=[...names].find(([,v])=>v.module==='Direct'&&v.original==='templatePlan')?.[0];
 const epoch=[...names].find(([,v])=>v.module==='Direct'&&v.original==='groupProgram')?.[0];
 const handlerDecls=new Set(decls.filter(n=>epoch!==undefined&&n.init?.type==='ArrowFunctionExpression'&&n.init.body.body?.[0]?.expression?.callee?.name===epoch));
 const handlerNames=new Set([...handlerDecls].map(n=>n.id.name));
 const dispatchDecls=new Set();
 for(const n of decls){
  if(n.init?.type!=='ArrowFunctionExpression'||topDecls.has(n))continue;
  const outer=[...topDecls].find(t=>t.start<n.start&&n.end<t.end);
  if(names.get(outer?.id.name)?.original!=='main')continue;
  const todo=[n.init.body];let calls=0;
  while(todo.length){const x=todo.pop();if(!x||typeof x!=='object')continue;
   if(['ArrowFunctionExpression','FunctionExpression'].includes(x.type))continue;
   if(x.type==='CallExpression'&&handlerNames.has(x.callee?.name))calls++;
   for(const v of Object.values(x))if(Array.isArray(v))todo.push(...v);else if(v&&typeof v==='object')todo.push(v);
  }
  if(calls)dispatchDecls.add(n);
 }

 const labels=['core','runtime','handlers','templates','application and startup'];
 const spans=[];
 for(const n of decls){
  const part=partAt(n.start);if(!part)continue;
  const info=topDecls.has(n)?names.get(n.id.name):null;
  let label=null;
  if(part.path.startsWith('core/')||part.path.startsWith('_core/'))label='core';
  else if(part.path.startsWith('platforms/'))label='runtime';
  else if(info?.original==='update')label='handlers';
  else if((info && /^(t\d|k\d|d[pgre]\d)/.test(info.original)) || (planName!==undefined&&n.init?.callee?.name===planName))label='templates';
  else if(handlerDecls.has(n)||dispatchDecls.has(n))label='handlers';
  if(label)spans.push({start:n.start,end:n.end,label,name:n.id.name});
 }
 // Keep outermost spans so e.g. runtime locals are never charged twice.
 spans.sort((a,b)=>a.start-b.start||b.end-a.end);
 const flat=[];for(const s of spans)if(!flat.some(p=>p.start<=s.start&&p.end>=s.end))flat.push(s);
 const remove=new Set();let before=br(source);const accounting=[];
 for(const label of labels.slice(0,-1)){
  remove.add(label);let at=0;const pieces=[];
  for(const s of flat)if(remove.has(s.label)){pieces.push(source.slice(at,s.start),`${s.name}=0`);at=s.end;}
  pieces.push(source.slice(at));const rest=pieces.join('');acorn.parse(rest,{ecmaVersion:'latest',sourceType:'module'});const after=br(rest);
  accounting.push({part:label,raw:flat.filter(s=>s.label===label).reduce((sum,s)=>sum+Buffer.byteLength(source.slice(s.start,s.end)),0),peelBrotli:before-after});before=after;
 }
 accounting.push({part:labels.at(-1),raw:Buffer.byteLength(source)-accounting.reduce((s,p)=>s+p.raw,0),peelBrotli:before});
 output.subjects[subject]={raw:Buffer.byteLength(source),brotli:br(source),parts:accounting};
 maps[subject]={source,names,partAt,functions,decls,topDecls,handlerDecls,dispatchDecls};
}
const records=statSync(profileDir).isFile()?JSON.parse(gunzipSync(readFileSync(profileDir))).profiles:readdirSync(profileDir).filter(f=>f.endsWith('.gz')).map(file=>JSON.parse(gunzipSync(readFileSync(`${profileDir}/${file}`))));
for(const row of records){
 const g=output.profiles[`${row.operation}/${row.subject}`]??={pages:0,functions:{},compileFrames:{},categories:{},gcTraceUs:0,deliveredDeltas:[],compileUs:0,heapBytes:{},heapTotal:0};g.pages++;
 const map=maps[row.subject];const nodes=new Map(row.profile.nodes.map(n=>[n.id,n]));
 const start=row.trace.find(e=>e.name==='s6-start');
 const lo=start.ts,hi=row.trace.find(e=>e.name==='s6-end').ts;
 const onMain=e=>e.pid===start.pid&&e.tid===start.tid;
 const compile=[];
 for(const e of row.trace.filter(e=>onMain(e)&&e.ph==='X'&&e.name==='V8.CompileCode'&&e.ts<hi&&e.ts+e.dur>lo).sort((a,b)=>a.ts-b.ts)){
  const last=compile.at(-1);
  if(last&&e.ts<=last.ts+last.dur)last.dur=Math.max(last.ts+last.dur,e.ts+e.dur)-last.ts;
  else compile.push({ts:e.ts,dur:e.dur});
 }
 for(const e of compile)g.compileUs+=Math.max(0,Math.min(hi,e.ts+e.dur)-Math.max(lo,e.ts));
 if(row.heap){
  g.heapPages=(g.heapPages??0)+1;
  const collect=(n,ancestor='native / unknown')=>{const f=n.callFrame;const outer=f.url?.endsWith('/_main.mjs')?map.decls.find(d=>map.topDecls.has(d)&&d.start<=f.columnNumber&&d.end>=f.columnNumber):null;const info=outer?map.names.get(outer.id.name):null;const name=info?`${info.module}.${info.original}`:ancestor;g.heapTotal+=n.selfSize;g.heapBytes[name]=(g.heapBytes[name]??0)+n.selfSize;n.children?.forEach(c=>collect(c,name));};collect(row.heap.head);
 }
 for(const e of row.trace)if(onMain(e)&&e.ph==='X'&&/^(MinorGC|MajorGC)$/.test(e.name)){g.gcTraceEvents=(g.gcTraceEvents??0)+1;g.gcTraceUs+=Math.max(0,Math.min(hi,e.ts+e.dur)-Math.max(lo,e.ts));}
 // DevTools reconstructs and sorts sample timestamps before assigning
 // intervals. V8 can deliver negative deltas; do not drop those samples.
 // https://github.com/ChromeDevTools/devtools-frontend/blob/main/front_end/models/cpu_profile/CPUProfileDataModel.ts
 let clock=row.profile.startTime;
 const ordered=(row.profile.samples??[]).map((id,i)=>{
  const delta=row.profile.timeDeltas[i]??0;clock+=delta;
  if(delta<0)g.negativeDeltas=(g.negativeDeltas??0)+1;
  return {id,time:clock};
 }).sort((a,b)=>a.time-b.time);
 ordered.forEach(({id,time:from},i)=>{
  const time=ordered[i+1]?.time??row.profile.endTime;
  const dt=time-from;if(i+1<ordered.length)g.deliveredDeltas.push(dt);
  const weight=Math.max(0,Math.min(time,hi)-Math.max(from,lo));if(!weight)return;
  const f=nodes.get(id).callFrame;let category='host / unattributed',name=f.functionName||'(anonymous)';
  if(f.functionName==='(garbage collector)')category='GC';
  else if(f.url.endsWith('/_main.mjs')){
   const offset=f.columnNumber;const part=map.partAt(offset);
   const owner=map.decls.filter(n=>n.start<=offset&&n.end>=offset).sort((a,b)=>(a.end-a.start)-(b.end-b.start))[0];
   const outer=map.decls.find(n=>map.topDecls.has(n)&&n.start<=offset&&n.end>=offset);
   const info=outer?map.names.get(outer.id.name):null;if(info)name=`${info.module}.${info.original} / ${name}`;
   if(info && /^(queue|turn|onTurn|flush|drain|schedule)$/.test(info.original))category='scheduler';
   else if(f.functionName.includes('$$root') || (info && /^(send|fire|dispatch|guard|delegate|listen|on)$/.test(info.original)))category='runtime dispatch';
   else if(info && /^(Cmd|Task|Http|Listen|Sub|Navigation|Api)$/.test(info.module))category='effects / commands';
   else if(part?.path.startsWith('core/')||part?.path.startsWith('_core/'))category='core';
   else if(info && /^(commands|subscriptions|applicationSubscriptions|step|settle)$/.test(info.original))category='effects / commands';
   else if(info?.module==='Direct'&&info.original.startsWith('template'))category='template runtime';
   else if(part?.path.startsWith('platforms/'))category='runtime patching / control';
   else if(info?.original==='update')category='handler / application';
   else category='generated handler / template';
   if(map.dispatchDecls.has(owner))category='generated dispatcher';
   else if(map.handlerDecls.has(owner))category='generated handler';
  }else if(f.url || /^(window\.addEventListener\.capture|globalThis\.fetch|end)$/.test(f.functionName))category='harness';
  const compiled=category==='GC'?0:Math.min(weight,compile.reduce((sum,e)=>sum+Math.max(0,Math.min(time,hi,e.ts+e.dur)-Math.max(time-dt,lo,e.ts)),0));
  g.categories['V8 compilation']=(g.categories['V8 compilation']??0)+compiled;
  g.categories[category]=(g.categories[category]??0)+weight-compiled;
  const key=`${name}:${f.columnNumber}`;g.functions[key]=(g.functions[key]??0)+weight;g.compileFrames[key]=(g.compileFrames[key]??0)+compiled;
 });
}
for(const g of Object.values(output.profiles)){
 g.functions=Object.entries(g.functions).sort((a,b)=>b[1]-a[1]).slice(0,30).map(([name,us])=>({name,sampledUsPerPage:us/g.pages,compilationOverlapUsPerPage:(g.compileFrames[name]??0)/g.pages}));
 g.categories=Object.fromEntries(Object.entries(g.categories).map(([k,v])=>[k,v/g.pages]));
 delete g.compileFrames;g.compileUs/=g.pages;g.heapTotal=g.heapPages?g.heapTotal/g.heapPages:null;g.heapBytes=Object.entries(g.heapBytes).sort((a,b)=>b[1]-a[1]).slice(0,15).map(([name,bytes])=>({name,bytesPerPage:bytes/g.heapPages}));
 g.gcTraceUs=g.gcTraceEvents?g.gcTraceUs/g.pages:null;g.deliveredDeltas.sort((a,b)=>a-b);g.medianDeliveredUs=g.deliveredDeltas[Math.floor(g.deliveredDeltas.length/2)];delete g.deliveredDeltas;
}
console.log(JSON.stringify(output,null,2));
