// The original catalogue, unchanged, at larger N. No padding or new strings to
// force the target. The seed and component prefix are stable across every point.
import fs from 'node:fs';import {createHash} from 'node:crypto';
import {application} from './catalogue.mjs';
import {writeApp} from './generate.mjs';
const here=import.meta.dirname;
const [family,nText,seedText='17']=process.argv.slice(2),n=Number(nText),seed=Number(seedText);
if(!family||!Number.isInteger(n)||n<1)throw Error('usage: stress-generate.mjs family N [seed]');
const shape=family==='mixed'?null:family,name=`stress-${family}-${seed}-${n}`;
const app=application(n,seed,shape),root=here+'/.out/apps/'+name;
const readRows=file=>fs.existsSync(file)?fs.readFileSync(file,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const done=new Set(readRows(here+'/results/stress/observations.jsonl').filter(r=>r.shape===shape&&r.rendering.brotli>=512000).map(r=>r.mode));
for(const r of readRows(here+'/results/stress/stopped.jsonl'))if(r.family===family)done.add(r.mode);
const specOnly=process.argv.includes('--spec-only')||['tea','direct','partial','static','local','cells'].every(m=>done.has(m));
if(!specOnly)writeApp(app,name);
else{
 // Baseline-only endpoints need configuration, not hundreds of thousands of
 // duplicate files. Still generate/hash the exact TEA sources reproducibly.
 fs.mkdirSync(root,{recursive:true});fs.writeFileSync(root+'/spec.json',JSON.stringify({...app,source:undefined,parts:app.parts.map(({source,...p})=>p)},null,2)+'\n');
 const files=[['Main.beni',app.source],...app.parts.map(p=>['Shape'+p.index+'.beni',p.source])].sort(([a],[b])=>a<b?-1:a>b?1:0),digest=createHash('sha256');let bytes=0;
 files.forEach(([file,source],i)=>{if(i)digest.update('\n');digest.update(file+'\n');digest.update(source);bytes+=Buffer.byteLength(source)});
 fs.writeFileSync(root+'/source-manifest.json',JSON.stringify({source_sha256:digest.digest('hex'),source_bytes:bytes,source_modules:files.length,scope:'Exact generated TEA source hashed in memory; baseline-only endpoint after native/prototype curves ended. Recreate files with writeApp(application(N, seed, shape), name). No padding.'})+'\n');
}

fs.writeFileSync(import.meta.dirname+'/.out/stress-current.json',JSON.stringify([{name,n,seed,shape}])+'\n');
console.log(name);
