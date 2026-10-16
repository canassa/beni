// Merge disjoint family queues and refresh the standalone report. No estimates.
import fs from 'node:fs';import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';
import {memoryRecovery} from './memory-recovery.mjs';
const here=import.meta.dirname,queues=[['primary','rendering-design'],['secondary','.rendering-design-secondary'],['tertiary','.rendering-design-tertiary']],base='azathoth:/home/canassa/beni-rendering-design-172/bench/';let previous='';
const jsonl=file=>fs.existsSync(file)?fs.readFileSync(file,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
for(;;){try{
 const rows=new Map(),native=new Map(),stops=new Map(),probes=new Map(),failures=[],protocols={};
 for(const [queue,folder] of queues){const dest=here+'/.out/stress-queues/'+queue;fs.mkdirSync(dest,{recursive:true});execFileSync('rsync',['-a',base+folder+'/results/stress/',dest+'/'],{stdio:'pipe'});
  protocols[queue]=JSON.parse(fs.readFileSync(dest+'/protocol.json'));
  execFileSync('rsync',['-a',base+folder+'/results/stress-today.jsonl',dest+'/native-builds.jsonl'],{stdio:'pipe'});
  for(const r of jsonl(dest+'/native-builds.jsonl')){const old=native.get(r.key);if(old&&old.sha256!==r.sha256)throw Error('Conflicting native build '+r.key);native.set(r.key,{...r,queue})}
  for(const r of jsonl(dest+'/observations.jsonl')){const key=r.name+'/'+r.mode,old=rows.get(key);if(old&&old.sha256!==r.sha256)throw Error('Conflicting checkpoint '+key);rows.set(key,{...r,queue})}
  for(const r of jsonl(dest+'/stopped.jsonl'))stops.set(r.family+'/'+r.mode+'/'+r.n+'/'+r.date,{...r,queue});
  for(const r of jsonl(dest+'/memory-probes.jsonl'))probes.set(r.name+'/'+r.mode+'/'+r.address_space_limit_bytes,{...r,queue});
  failures.push(...jsonl(dest+'/failures.jsonl').map(r=>({...r,queue})));
 }
 const a=protocols.primary,b=protocols.secondary;for(const p of Object.values(protocols))if(JSON.stringify(a.source_hashes)!==JSON.stringify(p.source_hashes)||a.compiler_sha256!==p.compiler_sha256)throw Error('Queue source/compiler identities differ');
 const dir=here+'/results/stress';fs.mkdirSync(dir,{recursive:true});
 const observations=[...rows.values()].sort((a,b)=>(a.shape||'mixed').localeCompare(b.shape||'mixed')||a.n-b.n||a.mode.localeCompare(b.mode)),{stopped,recovered}=memoryRecovery(observations,[...stops.values()]);
 const nativeBuilds=[...native.values()].sort((a,b)=>a.key.localeCompare(b.key));
 const memoryProbes=[...probes.values()],payload=JSON.stringify({observations,nativeBuilds,stopped,recovered,memoryProbes,protocols}),current=createHash('sha256').update(payload).digest('hex');
 if(current!==previous){
  fs.writeFileSync(dir+'/memory-probes.jsonl',memoryProbes.map(JSON.stringify).join('\n')+(memoryProbes.length?'\n':''));
  fs.writeFileSync(dir+'/native-builds.jsonl',nativeBuilds.map(JSON.stringify).join('\n')+'\n');
  fs.writeFileSync(dir+'/recovered.jsonl',recovered.map(JSON.stringify).join('\n')+(recovered.length?'\n':''));
  fs.writeFileSync(dir+'/observations.jsonl',observations.map(JSON.stringify).join('\n')+'\n');fs.writeFileSync(dir+'/stopped.jsonl',stopped.map(JSON.stringify).join('\n')+(stopped.length?'\n':''));
  fs.writeFileSync(dir+'/failures.jsonl',failures.map(JSON.stringify).join('\n')+(failures.length?'\n':''));fs.writeFileSync(dir+'/protocol.json',JSON.stringify({...a,queues:{primary:'mixed,form,nested,cluster',secondary:'list,tabs,thread,table',tertiary:'modal,filter,summary'},secondary_protocol:b,tertiary_protocol:protocols.tertiary},null,2)+'\n');
  fs.writeFileSync(dir+'/progress.json',JSON.stringify({updated:new Date().toISOString(),observations:observations.length,native_builds:nativeBuilds.length,crossings:observations.filter(r=>r.rendering.brotli>=512000).map(r=>({family:r.shape||'mixed',mode:r.mode,n:r.n,brotli:r.rendering.brotli})),compiler_limited:stopped.map(r=>({family:r.family,mode:r.mode,n:r.n})),recovered:recovered.map(r=>({family:r.family,mode:r.mode,...r.retry}))},null,2)+'\n');
  execFileSync(process.execPath,[here+'/html-report.mjs'],{stdio:'inherit'});previous=current;
 }
 }catch(e){console.error('Report refresh:',e.message);if(process.argv.includes('--once'))process.exitCode=1}
 if(process.argv.includes('--once'))break;
 await new Promise(r=>setTimeout(r,20000));
}
