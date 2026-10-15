#!/usr/bin/env node
// Recover the final-frontier skip accounting from the reducer's retained typed
// proposals. This does not run the compiler or change any verdict or minimum.
import {readFile,writeFile,copyFile,access} from 'node:fs/promises';
import {resolve} from 'node:path';
import {translate,Skip} from './bridge-translate.mjs';
const [directory]=process.argv.slice(2);
if(!directory || process.argv.length!==3) throw Error('usage: bridge-frontier.mjs <raw-campaign-dir>');
const reportPath=resolve(directory,'report.json'),backup=resolve(directory,'report-before-frontier.json');
try {await access(backup);} catch {await copyFile(reportPath,backup);}
const report=JSON.parse(await readFile(reportPath,'utf8'));
const summary={minima:0,skippedCandidates:{},reasonChanged:0,limitLeads:0};
for(const c of report.cases) {
 if(!c.reduction)continue;
 const dir=resolve(directory,'cases',c.id),tables=new Map(),skips={};
 const originalClass=c.lean.split(':')[0];
 for(const line of (await readFile(resolve(dir,'reductions.jsonl'),'utf8')).split('\n').filter(Boolean)) {
  const r=JSON.parse(line);
  if(r[0]==='table'){tables.set(r[1],r[2]);continue;}
  if(r[0]!=='program')throw Error('bad frontier record');
  if(r[5] || r[8].split(':')[0]!==originalClass)continue;
  try {
   if(r[13])throw new Skip(r[13]);
   if(JSON.stringify(r[12]).includes('"fn"'))throw new Skip('function-valued-observation');
   if(r[11]===null)throw new Skip('lean-value-execution-limit');
   const ds=tables.get(r[3]);if(!ds)throw Error('missing frontier table');
   translate(ds,r[4]);
  }catch(e){if(!(e instanceof Skip))throw e;skips[e.reason]=(skips[e.reason]??0)+1;}
 }
 c.reduction.skippedCandidates=skips;c.reduction.skipCountScope='final one-step frontier';
 c.reduction.reasonChanged=c.reduction.lean!==c.lean;c.reduction.limitLead=originalClass==='limit';
 summary.minima++;summary.reasonChanged+=Number(c.reduction.reasonChanged);summary.limitLeads+=Number(c.reduction.limitLead);
 for(const [reason,n] of Object.entries(skips))summary.skippedCandidates[reason]=(summary.skippedCandidates[reason]??0)+n;
 const ePath=resolve(dir,'evidence.json'),e=JSON.parse(await readFile(ePath,'utf8'));e.reduction=c.reduction;
 await writeFile(ePath,JSON.stringify(e,null,2));
}
await writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
await writeFile(resolve(directory,'frontier-summary.json'),JSON.stringify(summary,null,2)+'\n');
console.log(summary);
