#!/usr/bin/env node
// Opt-in shipping-checker negative controls. The live checkout is never edited.
import { mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../../..');
const dest=resolve(root,'zig-out/ownership-bridge-mutants'); mkdirSync(dest,{recursive:true});
const work=mkdtempSync(resolve(root,'zig-out/bridge-mutant-'));
const run=(cmd,args,cwd=root)=>{const r=spawnSync(cmd,args,{cwd,encoding:'utf8',maxBuffer:64*1024*1024});if(r.error)throw r.error;return r;};
const must=(...args)=>{const r=run(...args);if(r.status)throw Error(r.stderr+r.stdout);return r;};
const mutations=[
  ['dead','for (rec.holders) |h| {','for (rec.holders[0..0]) |h| {'],
  ['disjoint','for (spec.others) |av| {','for (spec.others[0..0]) |av| {'],
  ['shared','.shared => {\n                    cause = .top_level;','.shared => {\n                    if (false) cause = .top_level;']
];
let attached=false;
try {
  // worktree add requires an absent target; mkdtemp reserves the unique name.
  rmSync(work,{recursive:true}); must('git',['worktree','add','--detach',work,'HEAD']); attached=true;
  const source=resolve(work,'src/own/Ownership.zig'), original=readFileSync(source,'utf8');
  must('zorg',['build','-j8']);
  const baselineOut=resolve(dest,'baseline');
  const baselineRun=run(process.execPath,[resolve(root,'proofs/ownership/scripts/bridge.mjs'),'--ci',`--out=${baselineOut}`,'--jobs=8','--no-build']);
  writeFileSync(resolve(dest,'baseline.log'),baselineRun.stdout+baselineRun.stderr);
  if(baselineRun.status) throw Error('unmodified compiler baseline failed');
  const baseline=JSON.parse(readFileSync(resolve(baselineOut,'report.json'),'utf8'));
  const baselineLeads=new Set(baseline.cases.filter(c=>c.programLead).map(c=>c.id));
  const baselineSites=new Set(baseline.cases.flatMap(c=>c.siteLeads.map(s=>`${c.id}:${s}`)));
  const summary=[];
  for(const [name,before,after] of mutations) {
    if(original.split(before).length!==2)throw Error(`mutation anchor is not unique: ${name}`);
    writeFileSync(source,original.replace(before,after));
    const build=must('zorg',['build','-j8'],work);
    writeFileSync(resolve(dest,`${name}-build.log`),build.stdout+build.stderr);
    const out=resolve(dest,name);
    const checked=run(process.execPath,[resolve(root,'proofs/ownership/scripts/bridge.mjs'),'--ci',`--out=${out}`,`--compiler=${work}/zig-out/bin/beni`,'--jobs=8','--no-build']);
    writeFileSync(resolve(dest,`${name}.log`),checked.stdout+checked.stderr);
    if(![0,1].includes(checked.status)) throw Error(`bridge execution failed for ${name}: ${checked.stderr}`);
    const report=JSON.parse(readFileSync(resolve(out,'report.json'),'utf8'));
    const confirmed=report.cases.filter(c=>c.runtime.status==='confirmed');
    const added=report.cases.filter(c=>c.programLead && !baselineLeads.has(c.id));
    const addedSites=report.cases.flatMap(c=>c.siteLeads.filter(s=>!baselineSites.has(`${c.id}:${s}`)).map(site=>({id:c.id,site,runtime:c.runtime.status})));
    const errors=report.cases.filter(c=>!['unconfirmed','confirmed','blocked-by-other-refusals'].includes(c.runtime.status));
    const caught=(added.length>0 || addedSites.length>0) && errors.length===0;
    summary.push({hole:name,caught,added:added.map(c=>({id:c.id,runtime:c.runtime.status})),addedSites,confirmed:confirmed.length,sites:report.sites,errors});
    console.log(`Zig hole ${name}: ${caught?'caught':'MISSED'} (${added.length} new program verdict differences, ${confirmed.length} runtime disagreements)`);

  }
  writeFileSync(resolve(dest,'report.json'),JSON.stringify(summary,null,2)+'\n');
  if(summary.some(s=>!s.caught)) process.exitCode=1;
} finally {
  if(attached) must('git',['worktree','remove','--force',work]);
}
