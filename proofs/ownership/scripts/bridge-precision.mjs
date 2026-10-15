#!/usr/bin/env node
// Replay the precision direction using the exact campaign compiler and streams.
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {createInterface} from 'node:readline';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import assert from 'node:assert/strict';
import {translate,Skip} from './bridge-translate.mjs';
const [input,compiler,output]=process.argv.slice(2);
assert(input&&compiler&&output&&process.argv.length===5,
  'usage: bridge-precision.mjs raw-stream-directory compiler output.json.gz');
const base=resolve(input),exe=resolve(compiler),exec=promisify(execFile),leads=[];
const hash=x=>createHash('sha256').update(x).digest('hex');
const baseline=JSON.parse(await readFile(base+'/report.json','utf8'));
assert.equal(hash(await readFile(exe)),baseline.environment.compilerSha256,'use the original campaign compiler');
for(const stream of baseline.streams)
  assert.equal(hash(await readFile(base+'/'+stream.name)),stream.sha256,'stream hash');
let batch=[],total=0;
async function flush(){
  const ps=batch;batch=[];
  const dir=await mkdtemp('/tmp/bridge-precision-');
  try {
    for(const p of ps)await writeFile(`${dir}/${p.module}.beni`,p.source);
    const {stdout}=await exec(exe,['dump','--stage=ownership','--platform=browser-direct','--jobs=1',dir],{maxBuffer:32*1024*1024});
    const seen=new Set();let current;
    for(const line of stdout.split('\n')){
      if(!line)continue;
      let m=line.match(/^module (\S+)$/);
      if(m){
        current=ps.find(p=>p.module===m[1]);assert(current&&!seen.has(m[1]),'unexpected or repeated module');
        seen.add(m[1]);continue;
      }
      m=line.match(/^  (\d+):(\d+) (.+?): (accepted|rejected|pending)(?:(?: |: ?)(.*))?$/);
      if(m&&current){
        if(m[4]!=='accepted')current.refusals.push({row:+m[1],col:+m[2],operation:m[3],verdict:m[4],detail:m[5]??''});
        continue;
      }
      assert(/^  (summary |value |demands )|^(total |cause |pending )/.test(line),`unparsed ownership dump: ${line}`);
    }
    assert.equal(seen.size,ps.length,'missing module verdicts');
    for(const p of ps)if(p.refusals.length)leads.push(p);
    total+=ps.length;
  }finally{await rm(dir,{recursive:true,force:true});}
}
for(const stream of baseline.streams){
  const tables=new Map();
  for await(const line of createInterface({input:createReadStream(base+'/'+stream.name),crlfDelay:Infinity})){
    const r=JSON.parse(line);
    if(r[0]==='table'){tables.set(r[1],r[2]);continue;}
    assert(r[0]==='program'&&r.length===14,'obsolete stream');
    if(!r[5]||r[13]||JSON.stringify(r[12]).includes('"fn"')||r[11]===null)continue;
    let translation;
    try{translation=translate(tables.get(r[3]),r[4]);}
    catch(e){if(e instanceof Skip)continue;throw e;}
    batch.push({id:r[2],family:r[1],module:'P'+r[2].replaceAll('-','_'),source:translation.source,refusals:[]});
    if(batch.length>=128)await flush();
  }
}
if(batch.length)await flush();
assert.equal(total,18747);assert.equal(leads.length,401);
leads.sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
const categories=[['once','List.push: once'],['returned','List.push: it is returned'],['need','value: need'],['nested-exclusive','List.update: exclusive'],['initialize-exclusive',null]];
const primaryPatterns={},overlaps=[];
for(const p of leads){
  const keys=new Set(p.refusals.map(d=>d.operation.split(' ')[0]+': '+d.detail.split(':')[0]));
  const matches=categories.filter(([,v])=>v?keys.has(v):[...keys].some(k=>['List.push: exclusive','List.set: exclusive'].includes(k)));
  assert(matches.length,'unclassified precision lead');p.patterns=matches.map(([k])=>k);p.primaryPattern=p.patterns[0];
  primaryPatterns[p.primaryPattern]=(primaryPatterns[p.primaryPattern]??0)+1;
  if(matches.length>1)overlaps.push({id:p.id,patterns:p.patterns});
}
const report={leanAccepted:total,zigRefused:leads.length,primaryPatterns,overlaps,leads};
await writeFile(output,gzipSync(JSON.stringify(report),{level:9}));
console.log(JSON.stringify({...report,leads:leads.length}));
