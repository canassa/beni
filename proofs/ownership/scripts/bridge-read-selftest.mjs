#!/usr/bin/env node
// Drive the bridge through a real compiler, adding only dump protocol lines.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {translate} from './bridge-translate.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../../..');
const options=Object.fromEntries(process.argv.slice(2).map(a=>{const [k,...v]=a.slice(2).split('=');return [k,v.join('=')]}));
assert(options.input && options.compiler,'--input and --compiler are required');
const tables=new Map(); let chosen;
for(const line of (await readFile(options.input,'utf8')).trim().split('\n')) {
  const r=JSON.parse(line);
  if(r[0]==='table'){tables.set(r[1],r[2]);continue;}
  if(r[0]!=='program'||!r[5]||r[12][0]==='invalid'||r[13]||r[11]===null)continue;
  try {translate(tables.get(r[3]),r[4]);chosen={record:r,table:tables.get(r[3])};break;}
  catch(e){if(!e.reason)throw e;}
}
assert(chosen,'no accepted translatable fixture');
const dir=await mkdtemp('/tmp/beni-o1r-read-control-'); let passed=false;
try {
  const input=resolve(dir,'input.jsonl'),record=[...chosen.record];record[3]=0;
  await writeFile(input,JSON.stringify(['table',0,chosen.table])+'\n'+JSON.stringify(record)+'\n');
  for(const [name,line,accept] of [
    ['capture','  capture holder.field: read 4:7; before 3:2',true],
    ['hoist','  hoist holder.0: read 4:7; after operands 3:2',true],
    ['malformed','  capture holder: read missing; before 3:2',false],
  ]) {
    const wrapper=resolve(dir,`${name}.mjs`),out=resolve(dir,name);
    await writeFile(wrapper,`#!/usr/bin/env node\nimport {spawnSync} from 'node:child_process';\nconst args=process.argv.slice(2);const r=spawnSync(${JSON.stringify(resolve(options.compiler))},args,{encoding:'utf8',maxBuffer:16*1024*1024});\nif(r.error)throw r.error;let text=r.stdout;if(args[0]==='dump'&&args.includes('--stage=ownership'))text=text.replace(/^(module [^\\n]+\\n)/m,x=>x+${JSON.stringify(line+'\n')});process.stdout.write(text);process.stderr.write(r.stderr);process.exit(r.status??1);\n`,{mode:0o755});
    const ran=spawnSync(process.execPath,[resolve(root,'proofs/ownership/scripts/bridge.mjs'),`--input=${input}`,`--out=${out}`,`--compiler=${wrapper}`,'--no-build','--no-minimize','--jobs=1'],{cwd:root,encoding:'utf8',maxBuffer:16*1024*1024,timeout:120000});
    if(ran.error)throw ran.error;
    await writeFile(resolve(dir,`${name}.log`),ran.stdout+ran.stderr);
    if(accept)assert.equal(ran.status,0,ran.stdout+ran.stderr);
    else {
      assert.notEqual(ran.status,0,'malformed staging detail was accepted');
      const failure=JSON.parse(await readFile(resolve(out,'failure.json'),'utf8'));
      assert.match(failure.message,/unparsed ownership dump:.*capture holder: read missing/);
    }
  }
  passed=true; console.log('bridge capture/hoist detail and malformed-line controls: caught');
} finally {
  if(passed)await rm(dir,{recursive:true,force:true});
  else console.error(`bridge read-detail evidence retained: ${dir}`);
}
