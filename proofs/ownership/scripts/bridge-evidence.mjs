#!/usr/bin/env node
// Compact, replayable evidence: deduplicate source and declaration tables while
// retaining every lead, original/minimized runtime outcome and core minimum.
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
const [input, output] = process.argv.slice(2);
if (!input || !output || process.argv.length !== 4) throw Error('usage: bridge-evidence.mjs <campaign-dir> <evidence-dir>');
const dest=resolve(output), report=JSON.parse(await readFile(resolve(input,'report.json'),'utf8'));
await mkdir(resolve(dest,'sources'),{recursive:true});
const hash=x=>createHash('sha256').update(x).digest('hex');
const tables=new Map(), rows=[];
async function source(text) {
  const name=`M${hash(text)}.beni`;
  await writeFile(resolve(dest,'sources',name),text);
  return `sources/${name}`;
}
for(const c of report.cases) {
  const dir=resolve(input,'cases',c.id);
  const originals=(await readdir(dir)).filter(f=>f.endsWith('.beni') && f!=='Minimal.beni');
  if(originals.length!==1) throw Error(`ambiguous original source: ${c.id}`);
  const originalSource=await source(await readFile(resolve(dir,originals[0]),'utf8'));
  let minimum=null;
  if(c.reduction) {
    const [ds,main]=JSON.parse(await readFile(resolve(dir,'minimal-core.json'),'utf8'));
    const table=hash(JSON.stringify(ds)); tables.set(table,ds);
    minimum={source:await source(await readFile(resolve(dir,'Minimal.beni'),'utf8')),table,main};
  }
  rows.push({...c,originalSource,minimum});
}
rows.sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
await writeFile(resolve(dest,'cases.jsonl'),rows.map(c=>JSON.stringify(c)).join('\n')+'\n');
await writeFile(resolve(dest,'tables.jsonl'),[...tables].sort(([a],[b])=>a<b?-1:1).map(([id,ds])=>JSON.stringify([id,ds])).join('\n')+'\n');
await writeFile(resolve(dest,'report.json'),JSON.stringify({...report,cases:rows.length},null,2)+'\n');
console.log(`retained ${rows.length} cases, ${tables.size} declaration tables in ${dest}`);
