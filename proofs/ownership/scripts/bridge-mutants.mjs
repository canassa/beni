#!/usr/bin/env node
// Opt-in shipping-checker negative controls. The live checkout is never edited.
import { mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../../..');
const dest=resolve(root,'zig-out/ownership-bridge-mutants'); mkdirSync(dest,{recursive:true});
const work=mkdtempSync(resolve(root,'zig-out/bridge-mutant-'));
const run=(cmd,args,cwd=root)=>{const r=spawnSync(cmd,args,{cwd,encoding:'utf8',maxBuffer:64*1024*1024});if(r.error)throw r.error;return r;};
const must=(...args)=>{const r=run(...args);if(r.status)throw Error(r.stderr+r.stdout);return r;};
// Each control is one permissive edit of src/own/Ownership.zig: a list of
// unique [anchor, replacement] pairs. `dead`, `disjoint` and `shared` remove a
// whole loop or cause; the targeted six (the oracle review, 2026-10-15) each
// remove one rule: a list pattern's spread binding (`view`), a construction's
// later spread operands in Disjoint (`append`), a record update's use of its
// base (`record`), a once closure's later calls (`oncecall`), the fold
// accumulator's parameter-result shape (`foldret`) and keep-shape's taken
// supply (`keepshape`). `spreadcert` is a construction rule of this round's.
// A control the bridge cannot catch is reported as missed. Name controls on
// the command line to run only those.
const mutations=[
  ['dead',[['for (rec.holders) |h| {','for (rec.holders[0..0]) |h| {']]],
  ['disjoint',[['for (spec.others) |av| {','for (spec.others[0..0]) |av| {']]],
  ['shared',[['.shared => {\n                    cause = .top_level;','.shared => {\n                    if (false) cause = .top_level;']]],
  ['view',[['try w.bindPattern(inner, av);','try w.bindPattern(inner, &.{});']]],
  ['append',[['for (avs, 0..) |av, i| if (i != bi) {','for (avs, 0..) |av, i| if (i != bi and !items[i].spread) {'],
    ['            .base = avs[bi],\n            .others = others,','            .base = avs[bi],\n            .others = others[0..k],']]],
  ['record',[['try w.useOperand(base_inst, w.token(inst), names);','']]],
  ['oncecall',[['for (cl.call_probes.items) |p| {','for (cl.call_probes.items[0..0]) |p| {']]],
  ['foldret',[['.param => if (r.prov.a != k or r.prov.path != r.path) return null,','.param => {},']]],
  ['keepshape',[['k = try w.condAnd(k, try w.takenSupply(j, r.prov, ctx));','_ = &k;']]],
  // A construction that spreads a list which lives on keeps its base's
  // exclusivity (the stored-condition rule of §18.2 for spreads).
  ['spreadcert',[['spread_k = cond_lost;','spread_k = try w.condAnd(spread_k, cond_yes);']]],
];
const only=process.argv.slice(2);
for(const name of only) if(!mutations.some(([n])=>n===name)) throw Error(`unknown control ${name}`);
let attached=false;
try {
  // worktree add requires an absent target; mkdtemp reserves the unique name.
  rmSync(work,{recursive:true}); must('git',['worktree','add','--detach',work,'HEAD']); attached=true;
  const source=resolve(work,'src/own/Ownership.zig'), original=readFileSync(source,'utf8');
  must('zorg',['build','-j8'],work);
  const baselineOut=resolve(dest,'baseline');
  const baselineRun=run(process.execPath,[resolve(root,'proofs/ownership/scripts/bridge.mjs'),'--ci',`--out=${baselineOut}`,`--compiler=${work}/zig-out/bin/beni`,'--jobs=8','--no-build','--no-minimize']);
  writeFileSync(resolve(dest,'baseline.log'),baselineRun.stdout+baselineRun.stderr);
  if(baselineRun.status) throw Error('unmodified compiler baseline failed');
  const baseline=JSON.parse(readFileSync(resolve(baselineOut,'report.json'),'utf8'));
  const baselineLeads=new Set(baseline.cases.filter(c=>c.programLead).map(c=>c.id));
  const baselineSites=new Set(baseline.cases.flatMap(c=>c.siteLeads.map(s=>`${c.id}:${s}`)));
  const summary=[];
  for(const [name,edits] of mutations) {
    if(only.length && !only.includes(name)) continue;
    let mutated=original;
    for(const [before,after] of edits) {
      if(mutated.split(before).length!==2)throw Error(`mutation anchor is not unique: ${name}`);
      mutated=mutated.replace(before,()=>after);
    }
    writeFileSync(source,mutated);
    const build=must('zorg',['build','-j8'],work);
    writeFileSync(resolve(dest,`${name}-build.log`),build.stdout+build.stderr);
    const out=resolve(dest,name);
    const checked=run(process.execPath,[resolve(root,'proofs/ownership/scripts/bridge.mjs'),'--ci',`--out=${out}`,`--compiler=${work}/zig-out/bin/beni`,'--jobs=8','--no-build','--no-minimize']);
    writeFileSync(resolve(dest,`${name}.log`),checked.stdout+checked.stderr);
    const reportPath=resolve(out,'report.json');
    if(![0,1].includes(checked.status) || !existsSync(reportPath)) {
      const failurePath=resolve(out,'failure.json');
      const failure=existsSync(failurePath)?JSON.parse(readFileSync(failurePath,'utf8')):{message:checked.stderr};
      const caught=/^dump\/enforcement mismatch:/.test(failure.message);
      summary.push({hole:name,caught,caughtBySelfCheck:caught,failure});
      console.log(`Zig hole ${name}: ${caught?'caught by dump/enforcement self-check':'ERROR'}`);
      continue;
    }
    const report=JSON.parse(readFileSync(reportPath,'utf8'));
    const confirmed=report.cases.filter(c=>c.runtime.status==='confirmed');
    const added=report.cases.filter(c=>c.programLead && !baselineLeads.has(c.id));
    const addedSites=report.cases.flatMap(c=>c.siteLeads.filter(s=>!baselineSites.has(`${c.id}:${s}`)).map(site=>({id:c.id,site,runtime:c.runtime.status})));
    const errors=report.cases.filter(c=>!['unconfirmed','confirmed','blocked-by-other-refusals'].includes(c.runtime.status));
    const caught=(added.length>0 || addedSites.length>0) && errors.length===0;
    summary.push({hole:name,caught,added:added.map(c=>({id:c.id,runtime:c.runtime.status})),addedSites,confirmed:confirmed.length,sites:report.sites,errors});
    console.log(`Zig hole ${name}: ${caught?'caught':'MISSED'} (${added.length} new program verdict differences, ${confirmed.length} runtime disagreements)`);

  }
  writeFileSync(resolve(dest,only.length?`report-${only.join('-')}.json`:'report.json'),JSON.stringify(summary,null,2)+'\n');
  // Argued equivalent, with evidence, in CONSTRUCTIONS-RESULTS.md: reported, not required.
  const equivalent=['foldret','keepshape'];
  if(summary.some(s=>!s.caught && !equivalent.includes(s.hole))) process.exitCode=1;
} finally {
  if(attached) try {
    const removed=run('git',['worktree','remove','--force',work]);
    if(removed.status) throw Error(removed.stderr+removed.stdout);
  } catch(error) {
    console.error(`mutant cleanup failed (${work}): ${error.message}`);
    process.exitCode=1;
  }
}
