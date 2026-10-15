#!/usr/bin/env node
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createReadStream } from 'node:fs';
import { resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { availableParallelism } from 'node:os';
import { translate, constructs, siteAt, Skip } from './bridge-translate.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const own = resolve(root, 'proofs/ownership');
const children = new Set();
process.on('exit', () => { for (const child of children) child.kill('SIGKILL'); });
const options = Object.fromEntries(process.argv.slice(2).map(x => {
  if (!x.startsWith('--')) throw Error(`unexpected argument ${x}`);
  const [key, ...v] = x.slice(2).split('='); return [key, v.length ? v.join('=') : true];
}));
const allowed = ['input', 'out', 'jobs', 'compiler', 'ci', 'long', 'no-build', 'strict', 'suite', 'count', 'seeds', 'bound'];
for (const k of Object.keys(options)) if (!allowed.includes(k)) throw Error(`unknown option --${k}`);
const jobs = Number(options.jobs ?? Math.min(8, availableParallelism()));
if (!Number.isInteger(jobs) || jobs < 1 || jobs > 8) throw Error('--jobs must be 1..8');
const compiler = resolve(options.compiler ?? resolve(root, 'zig-out/bin/beni'));
const out = resolve(options.out ?? resolve(root, 'zig-out/ownership-bridge'));
await mkdir(out, { recursive: true });
function run(command, args, cwd = root, timeout = 120000) {
  return new Promise((yes, no) => {
    const child = spawn(command, args, { cwd, env: { ...process.env, LEAN_NUM_THREADS: String(jobs) }, stdio: ['ignore','pipe','pipe'] });
    children.add(child);
    let stdout = '', stderr = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.stdout.on('data', x => { stdout += x; }); child.stderr.on('data', x => { stderr += x; });
    child.on('error', e => { children.delete(child); clearTimeout(timer); no(e); });
    child.on('close', (status, signal) => { children.delete(child); clearTimeout(timer); if (signal) no(Error(`${command} killed: ${signal}`)); else yes({ status, stdout, stderr }); });
  });
}
const must = async (...args) => { const r = await run(...args); if (r.status) throw Error(`${args[0]} failed (${r.status}):\n${r.stderr}\n${r.stdout}`); return r; };
if (!options['no-build']) await must('zorg', ['build', `-j${jobs}`]);
const inputs = [];
if (options.input) inputs.push(resolve(options.input));
else {
  const suites = options.suite ? [options.suite] : options.ci ? ['fixtures', 'enumerate', 'generator'] : ['fixtures','enumerate','generator'];
  for (const suite of suites) {
    const seeds = suite === 'generator' ? String(options.seeds ?? (options.ci ? '17' : '17,20261011,314159')).split(',') : ['0'];
    for (const seed of seeds) {
      const input = resolve(out, `${suite}-${seed}.jsonl`);
      const count = Number(options.count ?? (options.ci ? 128 : 20000)), bound = Number(options.bound ?? (options.ci ? 1 : 2));
      if (!Number.isSafeInteger(count) || count < 1 || !Number.isSafeInteger(bound) || bound < 0 || !/^\d+$/.test(seed)) throw Error('invalid campaign count, bound or seed');
      console.log(`exporting ${suite} seed=${seed} count=${count} bound=${bound}`);
      await must(resolve(own, '.lake/build/bin/ownership'), ['bridge-export', String(count), seed, `--suite=${suite}`, `--enumerate-bound=${bound}`, `--out=${input}`], own, 3600000);
      inputs.push(input);
    }
  }
}
const total = { programs: 0, translated: 0, skipped: 0, agreements: 0, precision: 0, leads: 0,
  sites: { agreement: 0, precision: 0, lead: 0, unknown: 0, extra: 0, pending: 0 },
  skipReasons: {}, constructs: {}, families: {}, precisionPatterns: {}, cases: [], jobs };
const bump = (obj, k, n = 1) => { obj[k] = (obj[k] ?? 0) + n; };
const tables = new Map();
let batch = [], number = 0;
const queue = new Set();
async function confirmation(p, dir) {
  const result = {};
  for (const platform of ['browser-tea','browser-direct']) {
    const target = resolve(dir, platform);
    const built = await run(compiler, ['build', '--library', '--no-source-maps', '--no-cache', '--jobs=1', `--platform=${platform}`, `--out=${target}`, p.path]);
    if (built.status) return { status: 'build-failed', platform, ...built };
    const modulePath=resolve(target,`${p.module}.mjs`);
    let emitted=await readFile(modulePath,'utf8');
    const binding=`const ${p.module}$bridgeRead =`;
    if(emitted.split(binding).length !== 2) throw Error('observation identity missing or ambiguous');
    emitted=emitted.replace(binding,`const ${p.module}$bridgeRead$original =`);
    emitted+=`\nconst ${p.module}$bridgeRead = x => { globalThis.__bridgeReads.push(globalThis.__bridgeNormalize(x)); return ${p.module}$bridgeRead$original(x); };\n`;
    await writeFile(modulePath,emitted);
    const driver = resolve(dir, `${platform}-driver.mjs`);
    await writeFile(driver, `const normalize=x=>{if(typeof x==='function')throw Error('unobservable function');if(x&&typeof x.$plain==='function')x=x.$plain();if(Array.isArray(x))return x.map(normalize);if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).map(([k,v])=>[k,normalize(v)]));return x};\nglobalThis.__bridgeReads=[];globalThis.__bridgeNormalize=normalize;\nconst mod=await import(${JSON.stringify(modulePath)});const result=normalize(mod[${JSON.stringify(p.module+'$run')}]());const shared=Object.fromEntries(Object.entries(mod).filter(([k])=>/\\$g[0-9]+$/.test(k)).map(([k,v])=>[k.split('$').at(-1),normalize(v)]));console.log(JSON.stringify({result,reads:globalThis.__bridgeReads,shared}));\n`);
    const ran = await run(process.execPath, [driver], root, 10000);
    result[platform] = ran;
  }
  return { status: Object.values(result).some(r => r.status !== 0) ? 'execution-error' :
    JSON.stringify(JSON.parse(result['browser-tea'].stdout).result) !== JSON.stringify(p.record[11]) ? 'translation-mismatch' :
    result['browser-tea'].stdout === result['browser-direct'].stdout ? 'unconfirmed' : 'confirmed', runs: result };
}
// Greedy one-step minimum under the oracle's existing reduction relation.
// Every retained step rechecks both ownership verdicts and real execution.
async function minimize(original, dir, outcome) {
  let best = original, runtime = outcome, attempts = 0, rounds = 0;
  const input = resolve(dir, 'reduce-input.json'), output = resolve(dir, 'reductions.jsonl');
  for (;;) {
    await writeFile(input,JSON.stringify([best.ds,best.record[4]]));
    await must(resolve(own,'.lake/build/bin/ownership'),['bridge-reduce',`--input=${input}`,`--out=${output}`],own);
    const rows=(await readFile(output,'utf8')).split('\n').filter(Boolean).map(x=>JSON.parse(x));
    const reductions=new Map();
    const candidates=[];
    for(const r of rows) {
      if(r[0]==='table') reductions.set(r[1],r[2]);
      else if(r[0]==='program' && !r[5]) candidates.push(r);
      else if(r[0]!=='program') throw Error('bad reduction record');
    }
    candidates.sort((a,b)=>JSON.stringify([reductions.get(a[3]),a[4]]).length-JSON.stringify([reductions.get(b[3]),b[4]]).length);
    let changed=false;
    for (const record of candidates) {
      const ds=reductions.get(record[3]);
      if(!ds) throw Error('missing reduction table');
      if(JSON.stringify([ds,record[4]])===JSON.stringify([best.ds,best.record[4]])) continue;
      let translation;
      try {
        if (record[13]) continue;
        if (JSON.stringify(record[12]).includes('"fn"') || record[11] === null) continue;
        translation=translate(ds,record[4]);
      } catch(e) { if(e instanceof Skip) continue; throw e; }
      const p={...best,record,ds,translation,module:'Minimal',path:resolve(dir,'Minimal.beni')};
      await writeFile(p.path,translation.source); attempts++;
      const dumped=await must(compiler,['dump','--stage=ownership','--platform=browser-direct','--jobs=1','--diagnostics=json',p.path]);
      if (!parseDump(dumped.stdout,[p]).get(p.module).every(d=>d.verdict==='accepted')) continue;
      const result=await confirmation(p,dir);
      if (result.status !== 'confirmed' && !(runtime.status === 'unconfirmed' && result.status === 'unconfirmed')) continue;
      best=p; runtime=result; changed=true; rounds++; break;
    }
    if(!changed) break;
  }
  // Materialize the winning source and outputs after failed reduction attempts.
  const path=resolve(dir,'Minimal.beni'); await writeFile(path,best.translation.source);
  const final={...best,module:'Minimal',path};
  runtime=await confirmation(final,dir);
  await writeFile(resolve(dir,'minimal-core.json'),JSON.stringify([best.ds,best.record[4]]));
  return {runtime,attempts,rounds,minimum:'one-step under Oracle.reductions over main and declaration bodies',lean:best.record[8]};
}
function parseDump(text, programs) {
  const byModule = new Map(programs.map(p => [p.module, []])); let current = null;
  for (const line of text.split('\n')) {
    if (!line) continue;
    let m = line.match(/^module (\S+)$/);
    if (m) { current = byModule.get(m[1]); if (!current) throw Error(`unexpected module ${m[1]}`); continue; }
    m = line.match(/^  (\d+):(\d+) (.+?): (accepted|rejected|pending)(?:(?: |: ?)(.*))?$/);
    if (m && current) { current.push({ row:+m[1], col:+m[2], operation:m[3], verdict:m[4], detail:m[5] ?? '' }); continue; }
    if (/^  (summary |value |demands )|^(total |cause |pending )/.test(line)) continue;
    throw Error(`unparsed ownership dump: ${line}`);
  }
  return byModule;
}
async function checkBatch(programs, n) {
  const dir = await mkdtemp(resolve(out, `batch-${n}-`));
  for (const p of programs) { p.path = resolve(dir, `${p.module}.beni`); await writeFile(p.path, p.translation.source); }
  const dumped = await run(compiler, ['dump','--stage=ownership','--platform=browser-direct','--jobs=1','--diagnostics=json',dir]);
  if (dumped.status) {
    await writeFile(resolve(dir,'dump-error.json'), JSON.stringify(dumped,null,2));
    throw Error(`translation failed: ${dir}/dump-error.json`);
  }
  const reports = parseDump(dumped.stdout, programs);
  const enforced = await run(compiler, ['check','--platform=browser-direct','--no-cache','--jobs=1','--diagnostics=json',dir]);
  if (![0,1].includes(enforced.status)) throw Error(`unexpected enforcement exit ${enforced.status}: ${enforced.stderr}`);
  const diagnostics = JSON.parse(enforced.stderr || '[]');
  const errors = diagnostics.filter(d => d.severity === 'error');
  const permitted = ['list_still_used','list_may_be_shared','top_level_list_changed','view_changes_model'];
  if (errors.some(d => !permitted.includes(d.code))) {
    await writeFile(resolve(dir,'enforce-error.json'), JSON.stringify(enforced,null,2));
    throw Error(`unexpected enforcement diagnostics: ${dir}/enforce-error.json`);
  }
  const predicted = new Set(programs.flatMap(p=>reports.get(p.module).filter(d=>d.verdict !== 'accepted').map(d=>`${p.module}:${d.row}:${d.col}`)));
  const actual = new Set(errors.map(d=>`${basename(d.span.file,'.beni')}:${d.span.start.line}:${d.span.start.col}`));
  if (predicted.size !== actual.size || [...predicted].some(k=>!actual.has(k)) || (predicted.size === 0) !== (enforced.status === 0)) {
    await writeFile(resolve(dir,'enforcement-mismatch.json'), JSON.stringify({dumped,enforced},null,2));
    throw Error(`dump/enforcement mismatch: ${dir}`);
  }
  for (const p of programs) {
    const demands = reports.get(p.module), visited = new Set(p.record[6]), failed = p.record[7];
    const groups=new Map();
    for (const d of demands) {
      d.site=siteAt(p.translation.markers,d.row);
      if(!d.site){total.sites.extra++;continue;}
      if(d.verdict==='pending')total.sites.pending++;
      if(!groups.has(d.site))groups.set(d.site,[]);
      groups.get(d.site).push(d);
    }
    const siteLeads=[];
    for(const [site,ds] of groups) {
      // A declaration is checked under canonical summary assumptions. Its
      // failed inference is not a concrete call-site verdict in Zig.
      const lean=site===failed && site.startsWith('main') ? false :
        visited.has(site) && (site.startsWith('main') || p.record[5]) ? true : null;
      const zig=ds.every(d=>d.verdict==='accepted');
      if(lean===null)total.sites.unknown++;
      else if(lean===zig)total.sites.agreement++;
      else if(lean)total.sites.precision++;
      else {total.sites.lead++;siteLeads.push(site);}
    }
    const zig = demands.every(d=>d.verdict === 'accepted'), lean = p.record[5];
    const category = zig === lean ? 'agreements' : lean ? 'precision' : 'leads';
    total[category]++; bump(total.families[p.record[1]], category);
    if (category === 'precision') for (const d of demands.filter(d=>d.verdict !== 'accepted')) bump(total.precisionPatterns, `${d.operation.split(' ')[0]}: ${d.detail.split(':')[0]}`);
    if (category === 'leads' || siteLeads.length) {
      const evidence = resolve(out,'cases',p.record[2]); await mkdir(evidence,{recursive:true});
      await writeFile(resolve(evidence,`${p.module}.beni`),p.translation.source);
      const originalRuntime = zig ? await confirmation(p,evidence) : {status:"blocked-by-other-refusals"};
      const reduction = ["unconfirmed","confirmed"].includes(originalRuntime.status) ? await minimize(p,evidence,originalRuntime) : null;
      const runtime = reduction?.runtime ?? originalRuntime;
      const report = { id:p.record[2], family:p.record[1], lean:p.record[8], leanSite:failed, siteLeads, programLead:category==='leads', demands, originalRuntime, runtime, reduction };
      await writeFile(resolve(evidence,'evidence.json'),JSON.stringify({ ...report, record:p.record, declarations:p.ds },null,2));
      total.cases.push(report);
      console.log(`bridge lead ${p.record[2]}: ${runtime.status}`);
    }
  }
  // Sources of leads are retained independently. A clean batch needs only its
  // structured summary, avoiding tens of thousands of filesystem entries.
  await rm(dir,{recursive:true});
}
async function flush() {
  if (!batch.length) return;
  const data = batch; batch = []; const n = number++;
  const task = checkBatch(data,n); queue.add(task); task.finally(()=>queue.delete(task)).catch(()=>{});
  if (queue.size >= jobs) await Promise.race(queue);
}
for (const input of inputs) {
  tables.clear();
  const lines = createInterface({input:createReadStream(input), crlfDelay:Infinity});
  for await (const line of lines) {
    const record = JSON.parse(line);
    if (record[0] === 'table') { tables.set(record[1],record[2]); continue; }
    if (record[0] !== 'program' || record.length !== 14 || typeof record[13] !== 'string') throw Error('bad or obsolete bridge record');
    total.programs++; total.families[record[1]] ??= {programs:0,translated:0,skipped:0}; bump(total.families[record[1]],'programs');
    const ds = tables.get(record[3]); if (!ds) throw Error('missing declaration table');
    const counts = constructs(ds,record[4]);
    let translation;
    try {
      if (record[12]?.[0] === 'invalid') throw new Skip('ill-typed-core');
      if (record[13]) throw new Skip(record[13]);
      if (JSON.stringify(record[12]).includes('"fn"')) throw new Skip('function-valued-observation');
      if (record[11] === null) throw new Skip('lean-value-execution-limit');
      translation = translate(ds,record[4]);
    }
    catch (e) {
      if (!(e instanceof Skip)) throw e;
      total.skipped++; bump(total.skipReasons,e.reason); bump(total.families[record[1]],'skipped');
      for (const [k,n] of Object.entries(counts)) { total.constructs[k] ??= {translated:0,skipped:0}; total.constructs[k].skipped += n; }
      continue;
    }
    total.translated++; bump(total.families[record[1]],'translated');
    for (const [k,n] of Object.entries(counts)) { total.constructs[k] ??= {translated:0,skipped:0}; total.constructs[k].translated += n; }
    batch.push({record,ds,translation,module:`Case${total.programs}`});
    if (batch.length >= 32) await flush();
  }
}
await flush(); await Promise.all(queue);
total.cases.sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
await writeFile(resolve(out,'report.json'),JSON.stringify(total,null,2)+'\n');
console.log(JSON.stringify({...total,cases:total.cases.length},null,2));
if (total.cases.some(c=>!['unconfirmed','blocked-by-other-refusals'].includes(c.runtime.status)) || (options.strict && total.leads)) process.exitCode = 1;
