// Standalone, offline report. Re-run as checkpoints arrive; no network/CDN.
import fs from 'node:fs';
const here=import.meta.dirname,read=f=>JSON.parse(fs.readFileSync(here+'/'+f));
const original=[...read('results/sizes.json').observations,...read('results/solid-sizes.json').observations];
const stressFile=here+'/results/stress/observations.jsonl',stress=fs.existsSync(stressFile)?fs.readFileSync(stressFile,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const compact=r=>({name:r.name,n:r.n,seed:r.seed,family:r.shape||'mixed',mode:r.mode,raw:r.rendering.raw,brotli:r.rendering.brotli,gzip:r.rendering.gzip,runtime:r.runtime.brotli,full_brotli:r.full.brotli,app_increment:r.app_in_rendering_context,sha256:r.sha256,compiler_release_brotli:r.compiler_release?.rendering.brotli??null,source_bytes:r.source_bytes??null,compiler_cap_bytes:r.compiler_address_space_limit_bytes??null,compiler_ram_cap_bytes:r.compiler_physical_memory_limit_bytes??null});
const stopFile=here+'/results/stress/stopped.jsonl',stopped=fs.existsSync(stopFile)?fs.readFileSync(stopFile,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const nativeFile=here+'/results/stress/native-builds.jsonl',native=fs.existsSync(nativeFile)?fs.readFileSync(nativeFile,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const recoveredFile=here+'/results/stress/recovered.jsonl',recovered=fs.existsSync(recoveredFile)?fs.readFileSync(recoveredFile,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const data={native,stopped,recovered,finalized:fs.existsSync(here+'/results/stress/finalized.json')?read('results/stress/finalized.json'):null,generated:new Date().toISOString(),target:512000,unit:'kB = 1,000 bytes',rows:[...original,...stress].map(compact),protocol:fs.existsSync(here+'/results/stress/protocol.json')?read('results/stress/protocol.json'):null};
const mixtureModes=['tea','partial','static','local','cells','vanilla'],families=['list','form','tabs','nested','thread','cluster','table','modal','filter','summary'];
const indexed=new Map(data.rows.filter(r=>r.seed===17).map(r=>[r.family+'/'+r.mode+'/'+r.n,r]));
const mixtureN=[...new Set(data.rows.map(r=>r.n))].filter(n=>n>=64&&mixtureModes.every(m=>['mixed',...families].every(f=>indexed.has(f+'/'+m+'/'+n)))).sort((a,b)=>b-a)[0];
data.mixture=mixtureN?{n:mixtureN,seed:17,scope:'Mixed app versus the arithmetic mean of ten homogeneous apps at the same N, using measured responses. The mean is a comparison, not an additive prediction for the mixed app.',rows:mixtureModes.map(mode=>({mode,...Object.fromEntries(['raw','brotli','gzip'].map(metric=>{const mixed=indexed.get('mixed/'+mode+'/'+mixtureN)[metric],mean=families.reduce((sum,f)=>sum+indexed.get(f+'/'+mode+'/'+mixtureN)[metric],0)/families.length;return [metric,{mixed,homogeneous_mean:mean,change_percent:100*(mixed/mean-1)}]}))}))}:null;
const html=fs.readFileSync(here+'/report-template.html','utf8').replace('/*REPORT_DATA*/',JSON.stringify(data).replaceAll('<','\\u003c'));
// Publish complete snapshots so a browser refresh cannot read half a report.
const publish=(file,text)=>{fs.writeFileSync(file+'.tmp',text);fs.renameSync(file+'.tmp',file)};
publish(here+'/report.html',html);
publish(here+'/results/stress-report-data.json',JSON.stringify(data,null,2)+'\n');
console.log('HTML report:',data.rows.length,'measured bundles; maximum N',Math.max(...data.rows.map(r=>r.n)));
