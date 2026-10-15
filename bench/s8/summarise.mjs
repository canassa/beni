// All medians/IQRs use linear interpolation, including even sample counts.
import fs from 'node:fs';
const dir='bench/s8/results';
const read=f=>JSON.parse(fs.readFileSync(`${dir}/${f}`));
const q=(xs,p)=>{const a=xs.toSorted((a,b)=>a-b),pos=(a.length-1)*p,i=Math.floor(pos);return a.length?a[i]+(a[Math.min(i+1,a.length-1)]-a[i])*(pos-i):null};
const stat=xs=>({median:q(xs,.5),q1:q(xs,.25),q3:q(xs,.75),samples:xs.length});
const cell=xs=>{const s=stat(xs);return s.samples?`${s.median.toFixed(3)} [${s.q1.toFixed(3)}–${s.q3.toFixed(3)}] (${s.samples})`:'—'};
const group=(xs,keys,value)=>{const map=new Map();for(const x of xs){const k=JSON.stringify(Object.fromEntries(keys.map(k=>[k,x[k]])));if(!map.has(k))map.set(k,[]);map.get(k).push(x[value]);}return [...map].map(([k,v])=>({...JSON.parse(k),...stat(v)}))};
const output={};let md='All values ms unless stated otherwise; median [Q1–Q3] (n). No trimming.\n\n';
const ui=['vanillajs','solid1','solid2','beni-release','beni-direct-release','p3'];
const header=names=>`| condition | ${names.join(' | ')} |\n|---|${names.map(()=>'--:').join('|')}|\n`;
if(fs.existsSync(`${dir}/table.json`)){
 const r=read('table.json');output.table=group(r.samples,['benchmark','subject'],'script');md+='Unthrottled table, traced script.\n\n'+header(ui);
 for(const b of r.batches)md+=`| ${b.benchmark} | ${ui.map(s=>cell(r.samples.filter(x=>x.benchmark===b.benchmark&&x.subject===s).map(x=>x.script))).join(' | ')} |\n`;
}
if(fs.existsSync(`${dir}/sweeps.json`)){
 const r=read('sweeps.json');output.sweeps=group(r.samples,['sweep','op','param','subject'],'script');output.sweepFailures=r.failures;output.sweepSkipped=r.skipped;
 for(const sweep of r.sweeps)for(const op of sweep.ops){md+=`\n${sweep.id}/${op}, untraced except stream.\n\n`+header(ui);for(const p of sweep.params)md+=`| ${p} | ${ui.map(s=>cell(r.samples.filter(x=>x.sweep===sweep.id&&x.op===op&&x.param===p&&x.subject===s).map(x=>x.script))).join(' | ')} |\n`;}
}
if(fs.existsSync(`${dir}/todo-timing.json`)){
 const r=read('todo-timing.json');output.todo=group(r.rows,['n','op','subject','mode'],'script');const subs=[...new Set(r.rows.map(x=>x.subject))];md+='\nCriterion 6, untraced native events.\n\n'+header(subs);
 for(const n of [100,1000])for(const op of ['add','toggle','clear'])md+=`| ${n}/${op} | ${subs.map(s=>cell(r.rows.filter(x=>x.n===n&&x.op===op&&x.subject===s&&x.mode==='untraced').map(x=>x.script))).join(' | ')} |\n`;
}
if(fs.existsSync(`${dir}/conduit-timing.json`)){
 const r=read('conduit-timing.json');output.conduit=r.rows.flatMap(row=>row.subjects.map(s=>({operation:row.operation,subject:s.subject,...stat(s.raw.filter(x=>!x.tracing).map(x=>x.ms))})));
 md+='\nConduit, untraced native events.\n\n'+header(['tea','direct']);for(const row of r.rows)md+=`| ${row.operation} | ${row.subjects.map(s=>cell(s.raw.filter(x=>!x.tracing).map(x=>x.ms))).join(' | ')} |\n`;
}
if(fs.existsSync(`${dir}/apps-timing.json`)){
 const r=read('apps-timing.json');output.apps=group(r.rows,['app','operation','subject'],'ms');md+='\nReal applications, untraced native events.\n\n'+header(['tea','direct']);for(const k of new Set(r.rows.map(x=>JSON.stringify([x.app,x.operation])))){const [app,op]=JSON.parse(k);md+=`| ${app}/${op} | ${['tea','direct'].map(s=>cell(r.rows.filter(x=>x.app===app&&x.operation===op&&x.subject===s).map(x=>x.ms))).join(' | ')} |\n`;}
}
const pooled=new Map();
for(const round of [0,1,2,3]){
 const root=`${dir}/${round===0?"jfb":"jfb-"+round}/raw`;
 if(!fs.existsSync(root))continue;
 for(const file of fs.readdirSync(root).filter(f=>f.endsWith('.json'))){
  const row=JSON.parse(fs.readFileSync(`${root}/${file}`));
  const key=JSON.stringify([row.framework,row.benchmark]);
  if(!pooled.has(key))pooled.set(key,{...row,rounds:[],values:{}});
  const dst=pooled.get(key);dst.rounds.push(round);
  for(const [name,value] of Object.entries(row.values)){(dst.values[name]??=[]).push(...value.values);}
 }
}
if(pooled.size){
 output.jfb=[...pooled.values()].map(r=>({...r,values:Object.fromEntries(Object.entries(r.values).map(([key,xs])=>[key,stat(xs)]))}));
 const fw=[...new Set(output.jfb.map(x=>x.framework))];
 for(const column of ['total','script','DEFAULT']){md+=`\nOfficial JFB ${column}, pooled fixed rounds (throttled script is descriptive only).\n\n`+header(fw);for(const benchmark of new Set([...pooled.values()].filter(r=>r.values[column]).map(r=>r.benchmark))){md+=`| ${benchmark}${column==='DEFAULT'?(benchmark.includes('memory')?' (MiB)':benchmark.includes('size-')?' (KiB)':' (ms)'):''} | ${fw.map(f=>cell([...pooled.values()].find(r=>r.benchmark===benchmark&&r.framework===f)?.values[column]??[])).join(' | ')} |\n`;}}
}
fs.writeFileSync(`${dir}/summary.json`,JSON.stringify(output,null,2)+'\n');fs.writeFileSync(`${dir}/tables.md`,md);
console.log(md);
