#!/usr/bin/env node
// Deduplicate and compress the complete evidence while retaining every source,
// original/minimized runtime outcome and replayable typed core minimum.
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';
const args=process.argv.slice(2);
if(args[0]==='case') {
  const [,directory,id,part='report']=args;
  const bundle=JSON.parse(gunzipSync(await readFile(resolve(directory,'evidence.json.gz'))));
  const c=bundle.cases.find(c=>c.id===id);
  if(!c) throw Error(`unknown case ${id}`);
  if(part==='source' || part==='original') process.stdout.write(bundle.sources[part==='original'?c.originalSource:c.minimum?.source??c.originalSource]);
  else if(part==='core') {
    if(!c.minimum) throw Error('no minimum: direct execution was blocked by other refusals');
    console.log(JSON.stringify([bundle.tables[c.minimum.table],c.minimum.main]));
  } else if(part==='report') console.log(JSON.stringify(c,null,2));
  else throw Error('case part must be source, original, core or report');
} else {
  const [input,output]=args;
  if(!input || !output || args.length!==2) throw Error('usage: bridge-evidence.mjs <campaign-dir> <evidence-dir>, or case <evidence-dir> <id> [source|original|core|report]');
  const dest=resolve(output),report=JSON.parse(await readFile(resolve(input,'report.json'),'utf8'));
  await mkdir(dest,{recursive:true});
  const hash=x=>createHash('sha256').update(x).digest('hex');
  const tables=new Map(),sources=new Map(),rows=[];
  function source(text) {const name=`sources/M${hash(text)}.beni`;sources.set(name,text);return name;}
  for(const c of report.cases) {
    const dir=resolve(input,'cases',c.id);
    const originals=(await readdir(dir)).filter(f=>f.endsWith('.beni') && f!=='Minimal.beni');
    if(originals.length!==1) throw Error(`ambiguous original source: ${c.id}`);
    const originalSource=source(await readFile(resolve(dir,originals[0]),'utf8'));
    let minimum=null;
    if(c.reduction) {
      const [ds,main]=JSON.parse(await readFile(resolve(dir,'minimal-core.json'),'utf8'));
      const table=hash(JSON.stringify(ds));tables.set(table,ds);
      minimum={source:source(await readFile(resolve(dir,'Minimal.beni'),'utf8')),table,main};
    }
    const {runtime:_runtime,...reduction}=c.reduction??{};
    rows.push({...c,reduction:c.reduction?reduction:null,originalSource,minimum});
  }
  rows.sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
  const bundle={report:{...report,cases:rows.length},cases:rows,tables:Object.fromEntries([...tables].sort(([a],[b])=>a<b?-1:1)),sources:Object.fromEntries([...sources].sort(([a],[b])=>a<b?-1:1))};
  await writeFile(resolve(dest,'evidence.json.gz'),gzipSync(JSON.stringify(bundle),{level:9}));
  await writeFile(resolve(dest,'report.json'),JSON.stringify(bundle.report,null,2)+'\n');
  console.log(`retained ${rows.length} cases, ${tables.size} declaration tables and ${sources.size} sources in ${dest}`);
}
