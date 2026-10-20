#!/usr/bin/env node
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createReadStream, writeFileSync } from 'node:fs';
import { resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { availableParallelism } from 'node:os';
import { createHash } from 'node:crypto';
import { translate, constructs, siteAt, Skip } from './bridge-translate.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const own = resolve(root, 'proofs/ownership');
const children = new Set();
process.on('exit', () => { for (const child of children) child.kill('SIGKILL'); });
process.on('SIGTERM',()=>process.exit(143));
process.on('SIGINT',()=>process.exit(130));
const options = Object.fromEntries(process.argv.slice(2).map(x => {
  if (!x.startsWith('--')) throw Error(`unexpected argument ${x}`);
  const [key, ...v] = x.slice(2).split('='); return [key, v.length ? v.join('=') : true];
}));
const allowed = ['input', 'out', 'jobs', 'compiler', 'ci', 'long', 'no-build', 'strict', 'suite', 'count', 'seeds', 'bound', 'no-minimize'];
for (const k of Object.keys(options)) if (!allowed.includes(k)) throw Error(`unknown option --${k}`);
const jobs = Number(options.jobs ?? Math.min(8, availableParallelism()));
if (!Number.isInteger(jobs) || jobs < 1 || jobs > 8) throw Error('--jobs must be 1..8');
const compiler = resolve(options.compiler ?? resolve(root, 'zig-out/bin/beni'));
const out = resolve(options.out ?? resolve(root, 'zig-out/ownership-bridge'));
await mkdir(out, { recursive: true });
// The in-place platform. A build enforces when its chain's first `"lists"`
// says `in-place` (ownership-checker.md §28.2); the translated programs import
// no platform module, so the platform decides enforcement and nothing else.
// It was `browser-direct` until #423 retired it (2026-10-19); `browser-inline`
// is its successor and the one shipped in-place platform. `browser-tea` copies.
const inPlace = 'browser-inline';
await rm(resolve(out,'report.json'),{force:true});
await rm(resolve(out,'failure.json'),{force:true});
process.on('uncaughtExceptionMonitor',error=>{
  try { writeFileSync(resolve(out,'failure.json'),JSON.stringify({message:error.message,stack:error.stack},null,2)); } catch {}
});
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
  const suites = options.suite ? [options.suite] : ['fixtures','enumerate','generator','generator6'];
  for (const suite of suites) {
    const seeds = suite.startsWith('generator') ? String(options.seeds ?? (options.ci ? '17' : '17,20261011,314159')).split(',') : ['0'];
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
if(options.ci) await must(process.execPath,[resolve(own,'scripts/bridge-selftest.mjs'),`--input=${inputs[0]}`,`--compiler=${compiler}`]);
const total = { programs: 0, translated: 0, skipped: 0, valueChecked: 0, agreements: 0, precision: 0, leads: 0,
  sites: { agreement: 0, precision: 0, lead: 0, unknown: 0, extra: 0, pending: 0,
    ambiguousAgreement:0,ambiguousPrecision:0 },
  skipReasons: {}, constructs: {}, families: {}, precisionPatterns: {}, precisionPrograms: {}, precisionExamples: {}, cases: [], jobs,
  minimization: options['no-minimize'] ? 'disabled; original checks and paired executions unchanged' : 'historical persistent-runtime relation',
  environment:{node:process.version,platform:inPlace,compilerSha256:createHash('sha256').update(await readFile(compiler)).digest('hex'),
    oracleSha256:createHash('sha256').update(await readFile(resolve(own,'.lake/build/bin/ownership'))).digest('hex')},streams:[] };
const bump = (obj, k, n = 1) => { obj[k] = (obj[k] ?? 0) + n; };
const tables = new Map();
// Identical typed reductions recur across the enumerator's many contexts.
// Cache only intermediate probes; originals and final minima run afresh.
const reductionCache = new Map();
const normalizer = `const normalize=x=>{if(typeof x==='function')return '<function>';if(x&&typeof x.$plain==='function')x=x.$plain();if(Array.isArray(x))return x.map(normalize);if(x&&x.$==='Ok')return {f0:1,f1:0,f2:normalize(x.a)};if(x&&x.$==='Err')return {f0:0,f1:normalize(x.a),f2:0};if(x&&x.$==='BridgeEnd')return [];if(x&&x.$==='BridgeLink'){const out=[];for(let node=x;;node=node.b){if(node.$==='BridgeEnd')break;if(node.$!=='BridgeLink')throw Error('invalid bridge chain');out.push(normalize(node.a))}return out}if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,v])=>[k,normalize(v)]));return x};`;
let batch = [], number = 0;
const queue = new Set();
let firstFailure;
// Record fields compared by name: JavaScript orders `f10` before `f2`.
const canonical = x => Array.isArray(x) ? x.map(canonical) : x && typeof x === 'object' ?
  Object.fromEntries(Object.keys(x).sort().map(k => [k, canonical(x[k])])) : x;
async function confirmation(p, dir) {
  const result = {};
  for (const platform of ['browser-tea',inPlace]) {
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
    await writeFile(driver, `const normalize=x=>{if(typeof x==='function')return '<function>';if(x&&typeof x.$plain==='function')x=x.$plain();if(Array.isArray(x))return x.map(normalize);if(x&&x.$==='Ok')return {f0:1,f1:0,f2:normalize(x.a)};if(x&&x.$==='Err')return {f0:0,f1:normalize(x.a),f2:0};if(x&&x.$==='BridgeEnd')return [];if(x&&x.$==='BridgeLink'){const out=[];for(let node=x;;node=node.b){if(node.$==='BridgeEnd')break;if(node.$!=='BridgeLink')throw Error('invalid bridge chain');out.push(normalize(node.a))}return out}if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).map(([k,v])=>[k,normalize(v)]));return x};\nglobalThis.__bridgeReads=[];globalThis.__bridgeNormalize=normalize;\nconst mod=await import(${JSON.stringify(modulePath)});const result=normalize(mod[${JSON.stringify(p.module+'$run')}]());const shared=Object.fromEntries(Object.entries(mod).filter(([k])=>/\\$g[0-9]+$/.test(k)).map(([k,v])=>[k.split('$').at(-1),normalize(v)]));console.log(JSON.stringify({result,reads:globalThis.__bridgeReads,shared}));\n`);
    const ran = await run(process.execPath, [driver], root, 10000);
    result[platform] = ran;
  }
  return { status: Object.values(result).some(r => r.status !== 0) ? 'execution-error' :
    JSON.stringify(canonical(JSON.parse(result['browser-tea'].stdout).result)) !== JSON.stringify(canonical(p.record[11])) ? 'translation-mismatch' :
    result['browser-tea'].stdout === result[inPlace].stdout ? 'unconfirmed' : 'confirmed', runs: result };
}
// Check fidelity for the whole translated population, including agreements and
// precision differences. One library build and one Node process serve a batch.
async function checkValues(programs, dir) {
  const target=resolve(dir,'value');
  const built=await run(compiler,['build','--library','--no-source-maps','--no-cache','--jobs=1','--platform=browser-tea',`--out=${target}`,dir]);
  if(built.status) {
    await writeFile(resolve(dir,'value-build-error.json'),JSON.stringify(built,null,2));
    throw Error(`value build failed: ${dir}`);
  }
  const driver=resolve(dir,'value-driver.mjs');
  const cases=programs.map(p=>[resolve(target,`${p.module}.mjs`),`${p.module}$run`,p.record[11],p.record[2]]);
  await writeFile(driver,`${normalizer}\nfor(const [path,name,expected,id] of ${JSON.stringify(cases)}){const mod=await import(path);const actual=normalize(mod[name]());if(JSON.stringify(actual)!==JSON.stringify(normalize(expected)))throw Error(JSON.stringify({id,expected,actual}));}\n`);
  const ran=await run(process.execPath,[driver],root,30000);
  if(ran.status) {
    await writeFile(resolve(dir,'value-error.json'),JSON.stringify(ran,null,2));
    throw Error(`value fidelity failed: ${dir}/value-error.json`);
  }
  total.valueChecked+=programs.length;
  for(const p of programs) p.stream.valueChecked++;
}
// Greedy one-step minimum under the oracle's existing reduction relation.
// Every retained step rechecks both ownership verdicts and real execution.
async function minimize(original, dir, outcome) {
  let best = original, runtime = outcome, attempts = 0, rounds = 0, compilerRejected = 0;
  let skippedCandidates={};
  const reasonClass=original.record[8].split(':')[0];
  const input = resolve(dir, 'reduce-input.json'), output = resolve(dir, 'reductions.jsonl');
  for (;;) {
    skippedCandidates={};
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
      if(record[8].split(':')[0]!==reasonClass) continue;
      let translation;
      try {
        if (record[13]) throw new Skip(record[13]);
        if (record[11] === null) throw new Skip('lean-value-execution-limit');
        translation=translate(ds,record[4]);
      } catch(e) { if(e instanceof Skip) {bump(skippedCandidates,e.reason);continue;} throw e; }
      const p={...best,record,ds,translation,module:'Minimal',path:resolve(dir,'Minimal.beni')};
      await writeFile(p.path,translation.source); attempts++;
      const cacheKey=createHash('sha256').update(JSON.stringify([translation.source,record[11]])).digest('hex');
      if(!reductionCache.has(cacheKey)) {
        const probe=(async()=>{
          const dumped=await run(compiler,['dump','--stage=ownership',`--platform=${inPlace}`,'--jobs=1','--diagnostics=json',p.path]);
          if(dumped.status===1) {
            const diagnostics=JSON.parse(dumped.stderr);
            if(!diagnostics.some(d=>d.severity==='error')) throw Error('candidate failed without diagnostics');
            return {rejected:dumped};
          }
          if(dumped.status) throw Error(`candidate compiler failure: ${dumped.stderr}`);
          const reduced=parseDump(dumped.stdout,[p]).get(p.module);
          if(!reduced.every(d=>d.verdict==='accepted') || (reduced.limits??[]).length) return {};
          return {runtime:await confirmation(p,dir)};
        })();
        if(reductionCache.size>=20000) reductionCache.delete(reductionCache.keys().next().value);
        reductionCache.set(cacheKey,probe);
      }
      const checked=await reductionCache.get(cacheKey);
      if(checked.rejected) {
        compilerRejected++;
        await writeFile(resolve(dir,`rejected-candidate-${compilerRejected}.json`),JSON.stringify({record,ds,source:translation.source,dumped:checked.rejected},null,2));
        continue;
      }
      if(!checked.runtime) continue;
      const result=checked.runtime;
      if(!['unconfirmed','confirmed'].includes(result.status)) {
        await writeFile(resolve(dir,'reduction-runtime-error.json'),JSON.stringify({record,ds,source:translation.source,result},null,2));
        throw Error(`reduction runtime failure: ${dir}/reduction-runtime-error.json`);
      }
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
  return {runtime,attempts,rounds,compilerRejected,skippedCandidates,skipCountScope:'final one-step frontier',
    reasonChanged:best.record[8]!==original.record[8],limitLead:reasonClass==='limit',
    minimum:'one-step under Oracle.reductions over main and reachable declaration bodies; same rejection class; 5000-step evaluation budget; compiler-rejected candidates excluded',lean:best.record[8]};
}
function parseDump(text, programs) {
  const byModule = new Map(programs.map(p => [p.module, []])); let current = null;
  for (const line of text.split('\n')) {
    if (!line) continue;
    let m = line.match(/^module (\S+)$/);
    if (m) { current = byModule.get(m[1]); if (!current) throw Error(`unexpected module ${m[1]}`); continue; }
    m = line.match(/^  (\d+):(\d+) (.+?): (accepted|rejected|pending)(?:(?: |: ?)(.*))?$/);
    if (m && current) {
      // A record update (`{ r | F = … }`) is a demand line since #391, with
      // the operation `update` (`List.update` prints as `List.update`, so the
      // bare word is the record one). The Lean oracle has no record field
      // assignment (#316), so it has no verdict for the site; and the
      // compiler reports the demand without enforcing it (`Enforce.zig`,
      // until §31.9's codes land), so a rejected one has no diagnostic to
      // match either. Skipped until #316 lands.
      if (m[3].startsWith('update ')) continue;
      current.push({ row:+m[1], col:+m[2], operation:m[3], verdict:m[4], detail:m[5] ?? '' }); continue;
    }
    // A §16.7 limit at a declaration (`ownership_limit`): the module is refused
    // there, not at a demand site. Kept beside the module's demands.
    m = line.match(/^  limit (\S+): (\S+) (\d+), over (\d+)$/);
    if (m && current) { (current.limits ??= []).push({ declaration:m[1], kind:m[2], at:+m[3], cap:+m[4] }); continue; }
    // `records` (#391): the record demands' counts, per module and in total.
    if (/^  (summary |value |demands |records )|^(total |cause |pending |limits |records )/.test(line)) continue;
    throw Error(`unparsed ownership dump: ${line}`);
  }
  return byModule;
}
async function checkBatch(programs, n) {
  const dir = await mkdtemp(resolve(out, `batch-${n}-`));
  for (const p of programs) { p.path = resolve(dir, `${p.module}.beni`); await writeFile(p.path, p.translation.source); }
  const dumped = await run(compiler, ['dump','--stage=ownership',`--platform=${inPlace}`,'--jobs=1','--diagnostics=json',dir]);
  if (dumped.status) {
    await writeFile(resolve(dir,'dump-error.json'), JSON.stringify(dumped,null,2));
    throw Error(`translation failed: ${dir}/dump-error.json`);
  }
  const reports = parseDump(dumped.stdout, programs);
  const enforced = await run(compiler, ['check',`--platform=${inPlace}`,'--no-cache','--jobs=1','--diagnostics=json',dir]);
  if (![0,1].includes(enforced.status)) throw Error(`unexpected enforcement exit ${enforced.status}: ${enforced.stderr}`);
  const diagnostics = JSON.parse(enforced.stderr || '[]');
  const errors = diagnostics.filter(d => d.severity === 'error');
  const permitted = ['list_still_used','list_may_be_shared','top_level_list_changed','view_changes_model','ownership_limit'];
  if (errors.some(d => !permitted.includes(d.code))) {
    await writeFile(resolve(dir,'enforce-error.json'), JSON.stringify(enforced,null,2));
    throw Error(`unexpected enforcement diagnostics: ${dir}/enforce-error.json`);
  }
  // A limit is one `ownership_limit` diagnostic per `limit` dump line of its
  // module; it has no demand site, so it is matched by count, not by span.
  const limitErrors = errors.filter(d => d.code === 'ownership_limit');
  for (const p of programs) {
    const dumped_ = (reports.get(p.module).limits ?? []).length;
    const enforced_ = limitErrors.filter(d => basename(d.span.file,'.beni') === p.module).length;
    if (dumped_ !== enforced_) {
      await writeFile(resolve(dir,'enforcement-mismatch.json'), JSON.stringify({dumped,enforced},null,2));
      throw Error(`dump/enforcement limit mismatch in ${p.module}: ${dir}`);
    }
  }
  const siteErrors = errors.filter(d => d.code !== 'ownership_limit');
  const predicted = new Set(programs.flatMap(p=>reports.get(p.module).filter(d=>d.verdict !== 'accepted').map(d=>`${p.module}:${d.row}:${d.col}`)));
  const actual = new Set(siteErrors.map(d=>`${basename(d.span.file,'.beni')}:${d.span.start.line}:${d.span.start.col}`));
  // The dump places a `++` demand at its operator, while the diagnostic's
  // span is the whole construction: a demand matches the diagnostic starting
  // at it, or else the smallest unmatched one whose span contains it.
  const spans = new Map(siteErrors.map(d=>[`${basename(d.span.file,'.beni')}:${d.span.start.line}:${d.span.start.col}`,d.span]));
  const unmatched = new Set(actual), pending = [];
  for (const k of predicted) if (unmatched.has(k)) unmatched.delete(k); else pending.push(k);
  const before = (a, b) => a.line < b.line || (a.line === b.line && a.col <= b.col);
  let uncovered = 0;
  for (const k of pending) {
    const [m, row, col] = k.split(':'), at = {line: +row, col: +col};
    const covering = [...unmatched].filter(a => a.split(':')[0] === m && before(spans.get(a).start, at) && before(at, spans.get(a).end))
      .sort((a, b) => (spans.get(a).end.line - spans.get(a).start.line) - (spans.get(b).end.line - spans.get(b).start.line) ||
        (spans.get(a).end.col - spans.get(a).start.col) - (spans.get(b).end.col - spans.get(b).start.col));
    if (covering.length) unmatched.delete(covering[0]); else uncovered++;
  }
  if (uncovered || unmatched.size || (predicted.size === 0 && limitErrors.length === 0) !== (enforced.status === 0)) {
    await writeFile(resolve(dir,'enforcement-mismatch.json'), JSON.stringify({dumped,enforced},null,2));
    throw Error(`dump/enforcement mismatch: ${dir}`);
  }
  await checkValues(programs,dir);
  for (const p of programs) {
    const demands = reports.get(p.module), limits = demands.limits ?? [], visited = new Set(p.record[6]), failed = p.record[7];
    const multiplicity=new Map();
    for(const m of p.translation.markers) multiplicity.set(m.key,(multiplicity.get(m.key)??0)+1);
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
      let lean=site===failed && site.startsWith('main') ? false :
        visited.has(site) && (site.startsWith('main') || p.record[5]) ? true : null;
      const zig=ds.every(d=>d.verdict==='accepted');
      if(lean!==null && multiplicity.get(site)>1) {
        if(!lean) throw Error('ambiguous main-site failure');
        total.sites[zig?'ambiguousAgreement':'ambiguousPrecision']++;
        lean=null;
      }
      if(lean===null)total.sites.unknown++;
      else if(lean===zig)total.sites.agreement++;
      else if(lean)total.sites.precision++;
      else {total.sites.lead++;siteLeads.push(site);}
    }
    const zig = demands.every(d=>d.verdict === 'accepted') && limits.length === 0, lean = p.record[5];
    const category = zig === lean ? 'agreements' : lean ? 'precision' : 'leads';
    total[category]++; bump(total.families[p.record[1]], category); bump(p.stream,category);
    if (category === 'precision') {
      const refused = demands.filter(d=>d.verdict !== 'accepted');
      for (const d of refused) bump(total.precisionPatterns, `${d.operation.split(' ')[0]}: ${d.detail.split(':')[0]}`);
      for (const l of limits) bump(total.precisionPatterns, `limit: ${l.kind}`);
      // One pattern per program: its first refused demand's, or its first limit's.
      const first = refused.length ? `${refused[0].operation.split(' ')[0]}: ${refused[0].detail.split(':')[0]}` : `limit: ${limits[0].kind}`;
      bump(total.precisionPrograms, first);
      (total.precisionExamples[first] ??= []).length < 5 && total.precisionExamples[first].push(p.record[2]);
    }
    if (category === 'leads' || siteLeads.length) {
      const evidence = resolve(out,'cases',p.record[2]); await mkdir(evidence,{recursive:true});
      await writeFile(resolve(evidence,`${p.module}.beni`),p.translation.source);
      const originalRuntime = zig ? await confirmation(p,evidence) : {status:"blocked-by-other-refusals"};
      const reduction = !options['no-minimize'] && ["unconfirmed","confirmed"].includes(originalRuntime.status) ? await minimize(p,evidence,originalRuntime) : null;
      const runtime = reduction?.runtime ?? originalRuntime;
      const report = { id:p.record[2], family:p.record[1], lean:p.record[8], leanSite:failed, siteLeads, programLead:category==='leads', demands, limits, originalRuntime, runtime, reduction };
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
  if(firstFailure) throw firstFailure;
  if (!batch.length) return;
  const data = batch; batch = []; const n = number++;
  const task = checkBatch(data,n); queue.add(task);
  task.then(()=>queue.delete(task),error=>{firstFailure??=error;queue.delete(task);});
  if (queue.size >= jobs) await Promise.race(queue);
  if(firstFailure) throw firstFailure;
}
for (const input of inputs) {
  tables.clear();
  const stats={name:basename(input),programs:0,translated:0,skipped:0,valueChecked:0}; total.streams.push(stats);
  const hash=createHash('sha256'), stream=createReadStream(input);
  stream.on('data',chunk=>hash.update(chunk));
  const lines = createInterface({input:stream, crlfDelay:Infinity});
  for await (const line of lines) {
    if(firstFailure) throw firstFailure;
    const record = JSON.parse(line);
    if (record[0] === 'table') { tables.set(record[1],record[2]); continue; }
    if (record[0] !== 'program' || record.length !== 14 || typeof record[13] !== 'string') throw Error('bad or obsolete bridge record');
    total.programs++; stats.programs++; total.families[record[1]] ??= {programs:0,translated:0,skipped:0}; bump(total.families[record[1]],'programs');
    const ds = tables.get(record[3]); if (!ds) throw Error('missing declaration table');
    const counts = constructs(ds,record[4]);
    let translation;
    try {
      if (record[12]?.[0] === 'invalid') throw new Skip('ill-typed-core');
      if (record[13]) throw new Skip(record[13]);
      if (record[11] === null) throw new Skip('lean-value-execution-limit');
      translation = translate(ds,record[4]);
    }
    catch (e) {
      if (!(e instanceof Skip)) throw e;
      total.skipped++; stats.skipped++; bump(total.skipReasons,e.reason); bump(total.families[record[1]],'skipped');
      for (const [k,n] of Object.entries(counts)) { total.constructs[k] ??= {translated:0,skipped:0}; total.constructs[k].skipped += n; }
      continue;
    }
    total.translated++; stats.translated++; bump(total.families[record[1]],'translated');
    for (const [k,n] of Object.entries(counts)) { total.constructs[k] ??= {translated:0,skipped:0}; total.constructs[k].translated += n; }
    batch.push({record,ds,translation,stream:stats,module:`Case${total.programs}`});
    if (batch.length >= 32) await flush();
  }
  stats.sha256=hash.digest('hex');
}
await flush(); await Promise.all(queue);
if(firstFailure) throw firstFailure;
if(total.streams.some(s=>s.valueChecked!==s.translated) || total.valueChecked!==total.translated || total.agreements+total.precision+total.leads!==total.translated ||
  total.cases.filter(c=>c.programLead).length!==total.leads ||
  total.cases.reduce((n,c)=>n+c.siteLeads.length,0)!==total.sites.lead) throw Error('incomplete bridge accounting');
total.cases.sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0);
if(options.ci) {
  // Pinned CI stream floors make new skips an explicit, reviewable change.
  for(const [family,floor] of Object.entries({fixture:85,sync:61,targeted:548,enumerate:139,
    general:8,declarations:28,'branch-traversal':3,'fresh-tower':2,captures:4,
    'once-many-wrappers':3,'indexed-chain':5,'recursive-higher-order-limit':5,
    recursion:1,'fresh-nested':2,constructions:26,'construct-declarations':30})) {
    if((total.families[family]?.translated??0)<floor) throw Error(`CI translation coverage fell below ${family} floor ${floor}`);
  }
  if(total.translated*4<total.programs) throw Error('CI translation coverage fell below 25%');
}
if(!options.input && !options.ci && !options.suite && Number(options.count??20000)===20000 &&
  Number(options.bound??2)===2 && String(options.seeds??'17,20261011,314159')==='17,20261011,314159') {
  const baseline=JSON.parse(await readFile(resolve(own,'bridge-coverage.json'),'utf8'));
  if(total.programs!==baseline.programs) throw Error('long stream changed: review bridge coverage baseline');
  for(const [family,recorded] of Object.entries(baseline.families)) {
    const current=total.families[family];
    if(!current || current.programs!==recorded.programs || current.translated<Math.ceil(recorded.translated*baseline.minimumFraction)) {
      throw Error(`long translation coverage regressed: ${family}`);
    }
  }
}
await writeFile(resolve(out,'report.json'),JSON.stringify(total,null,2)+'\n');
console.log(JSON.stringify({...total,cases:total.cases.length},null,2));
if (total.cases.some(c=>!['unconfirmed','blocked-by-other-refusals'].includes(c.runtime.status)) || (options.strict && total.leads)) process.exitCode = 1;
