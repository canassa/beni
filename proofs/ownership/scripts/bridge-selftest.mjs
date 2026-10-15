#!/usr/bin/env node
// Black-box failure control: a real compiler invocation is forced to fail while the
// producer continues through valid, explicitly skipped exported programs.
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { translate } from './bridge-translate.mjs';
import {historicalFixedPrefix} from './bridge-fixed-prefix.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../../..');
const options=Object.fromEntries(process.argv.slice(2).map(x=>{const [k,...v]=x.slice(2).split('=');return [k,v.join('=')];}));
if(!options.input || !options.compiler) throw Error('selftest needs --input=<fixture-export> --compiler=<beni>');
const fixedText = await readFile(options.input, 'utf8');
const fixedBaseline = JSON.parse(await readFile(resolve(root, 'proofs/ownership/evidence/bridge-ci/report.json'), 'utf8'))
  .streams.find(s => s.name === 'fixtures-0.jsonl').sha256;
historicalFixedPrefix(fixedText, fixedBaseline);
const fixedLines = fixedText.trimEnd().split('\n');
const first = fixedLines.findIndex(line => JSON.parse(line)[0] === 'program');
const verdictChanged = [...fixedLines], changed = JSON.parse(verdictChanged[first]);
changed[5] = !changed[5]; verdictChanged[first] = JSON.stringify(changed);
assert.throws(() => historicalFixedPrefix(verdictChanged.join('\n') + '\n', fixedBaseline), /historical fixed source\/verdict stream changed/);
const sourceChanged = [...fixedLines], sourceRow = JSON.parse(sourceChanged[first]);
sourceRow[4] = ['atom', ['int', '123']]; sourceChanged[first] = JSON.stringify(sourceRow);
assert.throws(() => historicalFixedPrefix(sourceChanged.join('\n') + '\n', fixedBaseline));
const reordered = [...fixedLines], second = fixedLines.findIndex((line, i) => i > first && JSON.parse(line)[0] === 'program');
[reordered[first], reordered[second]] = [reordered[second], reordered[first]];
assert.throws(() => historicalFixedPrefix(reordered.join('\n') + '\n', fixedBaseline));
const omitted = fixedLines.filter((_, i) => i !== first);
assert.throws(() => historicalFixedPrefix(omitted.join('\n') + '\n', fixedBaseline));
console.log('historical fixed-prefix source/verdict/order/removal controls: caught');
const tables=new Map(); let translated, skipped;
for(const line of (await readFile(options.input,'utf8')).trim().split('\n')) {
  const r=JSON.parse(line);
  if(r[0]==='table'){tables.set(r[1],r[2]);continue;}
  if(r[12][0]==='invalid' || r[13] || r[11]===null) continue;
  if(JSON.stringify(r[12]).includes('"fn"')) skipped??={record:r,ds:tables.get(r[3])};
  else if(!translated) try {translate(tables.get(r[3]),r[4]);translated={record:r,ds:tables.get(r[3])};} catch(e){if(!e.reason)throw e;}
}
assert(translated && skipped,'fixture export must have a translated and a skipped program');
const dir=await mkdtemp(resolve(root,'zig-out/bridge-failure-control-'));
let passed=false;
try {
  for(const name of ['UnusedCapture','CaptureField','ResultCaseNonTail']) {
    const [ds,main]=JSON.parse(await readFile(resolve(root,`proofs/ownership/regressions/bridge/${name}.json`),'utf8'));
    const wire=resolve(dir,`${name}.json`),exported=resolve(dir,`${name}.jsonl`);
    // Removing the fresh prefix is an ordinary oracle reduction and exports
    // the exact fixture after independently typechecking the wire input.
    await writeFile(wire,JSON.stringify([ds,['let',1000,['atom',['int','0']],main]]));
    const checked=spawnSync(resolve(root,'proofs/ownership/.lake/build/bin/ownership'),['bridge-reduce',`--input=${wire}`,`--out=${exported}`],{encoding:'utf8',cwd:resolve(root,'proofs/ownership')});
    assert.equal(checked.status,0,checked.stderr);
    const records=(await readFile(exported,'utf8')).trim().split('\n').map(x=>JSON.parse(x));
    const record=records.find(r=>r[0]==='program' && JSON.stringify(r[4])===JSON.stringify(main));
    assert(record,'typed fixture was not exported');
    if(name==='UnusedCapture') {
      assert.equal(record[5],false);assert.match(record[8],/^Disjoint:/);
      assert.throws(()=>translate(ds,main),e=>e.reason==='unused-capture-slot');
    } else {
      assert.equal(record[5],true);
      const source=resolve(dir,`${name}.beni`),target=resolve(dir,`${name}-output`);
      await writeFile(source,translate(ds,main).source);
      const built=spawnSync(resolve(options.compiler),['build','--library','--no-cache','--no-source-maps','--jobs=1','--platform=browser-direct',`--out=${target}`,source],{encoding:'utf8'});
      assert.equal(built.status,0,built.stderr);
      const driver=resolve(dir,`${name}-driver.mjs`);
      await writeFile(driver,`import {${name}$run as run} from ${JSON.stringify(resolve(target,`${name}.mjs`))};console.log(JSON.stringify(run()));\n`);
      const ran=spawnSync(process.execPath,[driver],{encoding:'utf8'});
      assert.equal(ran.status,0,ran.stderr);
      if (name === 'ResultCaseNonTail') {
        assert.deepEqual(record[11], {f0: 1, f1: 0, f2: 99});
        assert.deepEqual(JSON.parse(ran.stdout), {$: 'Ok', a: 99});
      } else assert.deepEqual(JSON.parse(ran.stdout),record[11]);
    }
  }
  const input=resolve(dir,'input.jsonl'),out=resolve(dir,'output'),wrapper=resolve(dir,'compiler.mjs');
  await mkdir(out);
  const rows=[['table',0,translated.ds],['table',1,skipped.ds]];
  const program=(p,id,table)=>{const r=[...p.record];r[2]=id;r[3]=table;return JSON.stringify(r)+'\n';};
  const text=rows.map(r=>JSON.stringify(r)+'\n').join('')+
    Array.from({length:32},(_,i)=>program(translated,`translated-${i}`,0)).join('')+
    Array.from({length:50000},(_,i)=>program(skipped,`skipped-${i}`,1)).join('');
  await writeFile(input,text);
  await writeFile(wrapper,`#!/usr/bin/env node\nimport {spawnSync} from 'node:child_process';\nspawnSync(${JSON.stringify(resolve(options.compiler))},['--help'],{stdio:'inherit'});process.exit(1);\n`,{mode:0o755});
  const runner=resolve(options.runner??resolve(root,'proofs/ownership/scripts/bridge.mjs'));
  const ran=spawnSync(process.execPath,[runner,`--input=${input}`,`--out=${out}`,`--compiler=${wrapper}`,'--jobs=8','--no-build'],{encoding:'utf8',maxBuffer:8*1024*1024,timeout:120000});
  await writeFile(resolve(dir,'child.log'),ran.stdout+ran.stderr);
  if(ran.error) throw ran.error;
  assert.notEqual(ran.status,0,'failed batch was silently dropped');
  assert(!existsSync(resolve(out,'report.json')),'failed campaign published a complete report');
  const failure=JSON.parse(await readFile(resolve(out,'failure.json'),'utf8'));
  assert.match(failure.message,/^translation failed:/);
  passed=true;
  console.log('capture regressions and failed-batch black-box control: caught');
} finally {
  if(passed) await rm(dir,{recursive:true});
  else console.error(`failed-batch evidence retained: ${dir}`);
}
