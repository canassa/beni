// Validate the campaign's actual retained counts, never fill or drop cells.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root='bench/s8/results',read=p=>JSON.parse(fs.readFileSync(`${root}/${p}`));
const counts={};
const finite=(rows,field)=>{for(const r of rows)assert(typeof r[field]==='number'&&Number.isFinite(r[field])&&r[field]>=0,`Invalid ${field}: ${JSON.stringify(r)}`);};
function check(rows,keys,wanted){const cells=new Map();for(const r of rows){const k=JSON.stringify(keys.map(k=>r[k]));cells.set(k,(cells.get(k)??0)+1);}for(const [key,count]of cells)assert.equal(count,wanted,key);return cells.size;}
const table=read('table.json');finite(table.samples,'script');counts.table=table.samples.length;
assert.equal(check(table.samples,['benchmark','subject'],20),54);
const sw=read('sweeps.json');finite(sw.samples,'script');counts.sweeps=sw.samples.length;assert.equal(sw.failures.length,0,JSON.stringify(sw.failures));
check(sw.samples.filter(x=>x.sweep!=='stream'),['sweep','op','param','subject'],24);
check(sw.samples.filter(x=>x.sweep==='stream'),['sweep','op','param','subject'],2);
const subjects=['vanillajs','solid1','solid2','beni-release','beni-direct-release'];
for(const sweep of sw.sweeps)for(const op of sweep.ops)for(const param of sweep.params)for(const subject of subjects)assert(sw.samples.some(x=>x.sweep===sweep.id&&x.op===op&&x.param===param&&x.subject===subject),JSON.stringify({sweep:sweep.id,op,param,subject}));
const summary=read('summary.json');assert.deepEqual([...new Set(summary.todo.map(x=>x.n))].sort((a,b)=>a-b),[100,1000]);assert.equal(summary.todo.length,30);for(const row of summary.todo)assert.equal(row.samples,20);
const td=read('todo-timing.json');finite(td.rows,'script');counts.todo=td.rows.length;assert.equal(check(td.rows,['n','op','subject','mode'],20),30);
const apps=read('apps-timing.json');finite(apps.rows,'ms');counts.apps=apps.rows.length;assert.equal(check(apps.rows,['app','operation','subject'],20),10);
const con=read('conduit-timing.json');counts.conduit=0;assert.equal(con.rows.length,3);for(const row of con.rows){assert.equal(row.subjects.length,2);for(const s of row.subjects){finite(s.raw,'ms');finite(s.raw.filter(x=>x.tracing),'scriptMs');assert.equal(s.raw.filter(x=>!x.tracing).length,20);assert.equal(s.raw.filter(x=>x.tracing).length,20);assert.equal(s.raw.filter(x=>!x.tracing&&x.position===0).length,10);assert.equal(s.raw.filter(x=>!x.tracing&&x.position===1).length,10);counts.conduit+=s.raw.length;}}
for(const label of ["jfb","jfb-1","jfb-2","jfb-3"]){
 const meta=read(`${label}/meta.json`);assert.equal(meta.retried.length,0);assert.equal(meta.beniSha256,read('app-builds.json').compilerSha256);const raw=`${root}/${label}/raw`;const files=fs.readdirSync(raw).filter(f=>f.endsWith('.json'));counts[label]=files.length;assert.equal(files.length,60);
 for(const f of files){const r=JSON.parse(fs.readFileSync(`${raw}/${f}`));for(const v of Object.values(r.values))finite(v.values.map(value=>({value})),'value');if(r.type==='cpu')for(const v of Object.values(r.values))assert.equal(v.values.length,r.benchmark==='04_select1k'?15:5,f);if(r.type==='memory')for(const v of Object.values(r.values))assert.equal(v.values.length,5,f);}
}
const builds=read('app-builds.json'),prepared=read('prepared-artifacts.json');
for(const b of builds.apps.filter(b=>b.app==='table'&&b.status===0))assert.equal(prepared.files[`bench/jfb/work/frameworks/keyed/beni-${b.platform}/dist/_main.mjs`],b.sha256,'JFB/table executable differs');
for(const b of builds.apps.filter(b=>b.app==='conduit'&&b.status===0))assert.equal(con.sources[`browser-${b.platform}-release`],b.sha256,'Conduit timed/byte executable differs');
assert.equal(read('artifact-verification.json').compilerSha256,builds.compilerSha256);
for(const b of builds.apps.filter(b=>b.status===0)){assert.equal(b.parts.reduce((s,p)=>s+p.orderedBrotli,0),b.size.brotli);assert(b.parts.find(p=>p.part==='core').rawSpans>0);assert(b.parts.find(p=>p.part==='runtime').rawSpans>0);}
fs.writeFileSync(`${root}/audit.json`,JSON.stringify({passed:true,counts,method:'Counts and completeness only; behavioral evidence is in harness postconditions and the test logs.'},null,2)+'\n');console.log(counts);
