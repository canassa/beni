#!/usr/bin/env node
// Judge the original 2,358 leads, not the persistent JavaScript executions.
// Run inside nix develop .#ownership, from proofs/ownership.
import {readFile,writeFile,mkdir,rm,mkdtemp} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';
import {gunzipSync,gzipSync} from 'node:zlib';import assert from 'node:assert/strict';
import {translate} from './bridge-translate.mjs';
const own=resolve(dirname(fileURLToPath(import.meta.url)),'..'),root=resolve(own,'../..');
const args=process.argv.slice(2);
assert(args.length<=1,'usage: bridge-triage.mjs [output-directory]');
const dest=resolve(args[0]??resolve(own,'evidence/bridge-triage'));
await mkdir(dest,{recursive:true});await rm(resolve(dest,'report.json'),{force:true});
const packed=await readFile(resolve(own,'evidence/bridge-long/evidence.json.gz'));
const bundle=JSON.parse(gunzipSync(packed)),leads=bundle.cases.filter(c=>c.programLead);
assert.equal(leads.length,2358);
const byId=new Map(leads.map(c=>[c.id,c]));
const work=await mkdtemp(resolve(root,'zig-out/bridge-triage-replay-'));
const hash=x=>createHash('sha256').update(x).digest('hex');
const input=leads.map(c=>c.id+'\t'+JSON.stringify([bundle.tables[c.minimum.table],c.minimum.main])).join('\n')+'\n';
await writeFile(resolve(work,'leads.tsv'),input);
execFileSync('lake',['build','triage'],{cwd:own,stdio:'inherit'});
const exe=resolve(own,'.lake/build/bin/triage');
execFileSync(exe,[resolve(work,'leads.tsv'),resolve(work,'judgments.jsonl')],{cwd:own,stdio:'inherit'});
const rows=(await readFile(resolve(work,'judgments.jsonl'),'utf8')).trim().split('\n').map(JSON.parse);
assert.equal(rows.length,4716);
const groups=JSON.parse(await readFile(resolve(own,'evidence/bridge-triage/clusters.json'),'utf8'));
const assigned=new Map();for(const [cluster,ids]of Object.entries(groups))for(const id of ids){assert(!assigned.has(id));assigned.set(id,cluster);}
const cases=new Map(),tables={};
for(const row of rows){
 assert.equal(row.diverges,JSON.stringify(row.value)!==JSON.stringify(row.inPlace));
 const c=byId.get(row.id);assert(c,'unexpected case');
 const pair=cases.get(c.id)??{id:c.id,cluster:null};assert(!pair[row.phase],'duplicate phase');
 if(row.phase==='original'){
  assert.equal(row.lean,c.lean,'regenerated verdict');
  assert.equal(translate(...row.core).source,bundle.sources[c.originalSource],'original source fidelity');
  assert.equal(row.diverges,assigned.has(c.id),'cluster membership');
  pair.cluster=assigned.get(c.id)??null;
 }else{
  assert.equal(row.phase,'minimum');assert.deepEqual(row.core,[bundle.tables[c.minimum.table],c.minimum.main]);
 }
 const [ds,main]=row.core,key=hash(JSON.stringify(ds));tables[key]=ds;
 const {core,...rest}=row;pair[row.phase]={...rest,verdict:row.diverges?'confirmed by the in-place interpreter':'Lean precision lead',core:{table:key,main}};cases.set(c.id,pair);
}
const pairs=[...cases.values()].sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
assert(pairs.every(p=>p.original&&p.minimum));assert.equal(pairs.length,2358);
const witnesses=JSON.parse(await readFile(resolve(own,'regressions/bridge/Triage.json'),'utf8'));
await writeFile(resolve(work,'witnesses.tsv'),Object.entries(witnesses).map(([id,p])=>id+'\t'+JSON.stringify(p)).join('\n')+'\n');
execFileSync(exe,[resolve(work,'witnesses.tsv'),resolve(work,'witnesses.jsonl'),'--only'],{cwd:own,stdio:'inherit'});
const twins=(await readFile(resolve(work,'witnesses.jsonl'),'utf8')).trim().split('\n').map(JSON.parse);
assert.equal(twins.length,6);assert(twins.every(t=>t.diverges&&t.lean));
const confirmed=pairs.filter(p=>p.original.diverges).length;
const report={inputEvidenceSha256:hash(packed),originals:pairs.length,confirmed,leanImprecise:pairs.length-confirmed,
 verdicts:{confirmed:'confirmed by the in-place interpreter',agrees:'Lean precision lead'},
 clusters:Object.fromEntries(Object.entries(groups).map(([k,v])=>[k,v.length])),
 minima:{diverge:pairs.filter(p=>p.minimum.diverges).length,
  erasedOriginalDivergence:pairs.filter(p=>p.original.diverges&&!p.minimum.diverges).length,
  introducedDivergence:pairs.filter(p=>!p.original.diverges&&p.minimum.diverges).length},
 observation:'The complete Lean Trace: finalValue, reads and externalReads. Execution/type errors are fatal.',
 originalReplay:'Existing fixture/targeted/enumerate-2/v5 seeded streams regenerated; each original Lean refusal and emitted beni source match the retained campaign exactly.',
 proofStatus:'Neither checker nor interpreter changed. Three existing unproved soundness statements remain.'};
assert.equal(confirmed,201);assert.equal(report.leanImprecise,2157);
await writeFile(resolve(dest,'judgments.json.gz'),gzipSync(JSON.stringify({report,tables,cases:pairs,witnesses:twins}),{level:9}));
await writeFile(resolve(dest,'report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
