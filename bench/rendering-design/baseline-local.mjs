// One bounded baseline worker on a second host. Every output is measured;
// the cross-host controls must pass before launching this driver.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';
const here=import.meta.dirname,reference=path.resolve(process.argv[2]||''),dir=here+'/results/stress',log=dir+'/observations.jsonl',target=512000;
const hash=x=>createHash('sha256').update(x).digest('hex'),read=file=>fs.existsSync(file)?fs.readFileSync(file,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
if(!process.argv[2]||!fs.existsSync(reference))throw Error('baseline-local.mjs reference-observations.jsonl');
const protocol=JSON.parse(fs.readFileSync(dir+'/protocol.json'));
const control=JSON.parse(fs.readFileSync(dir+'/local-host-check.json'));
if(!control.passed||control.node!==process.version||control.arch!==process.arch||control.platform!==process.platform||!read(reference).some(r=>r.name===control.name&&r.mode==='vanilla'&&r.sha256===control.sha256))throw Error('Missing matching cross-host control');
for(const [file,expected] of Object.entries(protocol.source_hashes))if(hash(fs.readFileSync(here+'/'+file))!==expected)throw Error('Measurement source changed: '+file);
const host={platform:process.platform,arch:process.arch,node:process.version,cpu:os.cpus()[0].model,heap_mib:6144,workers:1};
fs.writeFileSync(dir+'/host.json',JSON.stringify(host,null,2)+'\n');
const unique=()=>{const m=new Map();for(const r of [...read(reference),...read(log)]){const key=r.name+'/'+r.mode,old=m.get(key);if(old&&old.sha256!==r.sha256)throw Error('Conflicting host output '+key);m.set(key,r)}return [...m.values()]};
const families=['form','tabs','nested','thread','cluster','table','modal','filter','summary'],pending=families.map(family=>({family,mode:'vanilla'}));
function run(file,args=[],env={}){const out=execFileSync(process.execPath,['--stack-size=16384','--max-old-space-size=6144',here+'/'+file,...args],{env:{...process.env,RESEARCH_LOCK:'',...env},encoding:'utf8',maxBuffer:8*1024*1024});if(out.trim())console.log(out.trim())}
while(pending.length){
 const job=pending.shift(),{family,mode}=job,rows=unique().filter(r=>r.shape===family&&r.mode===mode&&r.seed===17).sort((a,b)=>a.n-b.n);
 if(rows.some(r=>r.rendering.brotli>=target))continue;
 const last=rows.at(-1),before=rows.at(-2);let next=last?last.n*1.5:64;
 if(last&&before&&last.rendering.brotli>=target*.65){const slope=(last.rendering.brotli-before.rendering.brotli)/(last.n-before.n);if(slope>0)next=Math.min(next,last.n+(target*1.025-last.rendering.brotli)/slope)}
 const n=Math.ceil(Math.max((last?.n||0)+16,next)/16)*16,name='stress-'+family+'-17-'+n,root=here+'/.out/apps/'+name;
 console.log('LOCAL',new Date().toISOString(),family,n,mode);
 if(!fs.existsSync(root+'/source-manifest.json')){
  run('stress-generate.mjs',[family,String(n),'17','--spec-only']);
  const file=root+'/source-manifest.json',manifest=JSON.parse(fs.readFileSync(file));manifest.scope='Exact generated TEA sources hashed in memory for independent baseline pricing. Native and prototype curves are measured separately; no compiler invocation on this host.';fs.writeFileSync(file,JSON.stringify(manifest)+'\n');
 }
 const out=here+'/.out/measured/'+name,cache=out+'/'+mode+'-size.json';
 if(!fs.existsSync(cache))run('stress-worker.mjs',[name,mode]);
 const row={...JSON.parse(fs.readFileSync(cache)),measurement_host:host},code=fs.readFileSync(out+'/'+mode+'.js');
 if(row.name!==name||row.mode!==mode||row.sha256!==hash(code)||row.source_sha256!==JSON.parse(fs.readFileSync(root+'/source-manifest.json')).source_sha256)throw Error('Local price identity changed');
 const known=unique().find(r=>r.name===name&&r.mode===mode);if(known&&known.sha256!==row.sha256)throw Error('Cross-host output mismatch');
 if(!read(log).some(r=>r.name===name&&r.mode===mode))fs.appendFileSync(log,JSON.stringify(row)+'\n');
 console.log('LOCAL PRICED',family,n,row.rendering.brotli);
 if(row.rendering.brotli<target)pending.push(job);
}
fs.writeFileSync(dir+'/complete.json',JSON.stringify({completed:new Date().toISOString(),scope:'All nine remaining vanilla family curves have measured crossings.'},null,2)+'\n');
