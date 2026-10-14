// Build the unchanged Conduit subject; measure bytes and actual handler visits.
// The instrumented copies are used only for counts, never speed measurements.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync, mkdirSync, cpSync, rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { brotliCompressSync, constants } from 'node:zlib';
const repo = resolve(import.meta.dirname, '../..');
const beni = resolve(repo, process.env.BENI ?? 'zig-out/safe/bin/beni');
const work = join(repo, 'zig-out/conduit-measured');
mkdirSync(work, {recursive: true});
const run = (args) => execFileSync(beni, args, {cwd: repo, encoding: 'utf8', maxBuffer: 1 << 28});
const files = (dir) => readdirSync(dir, {withFileTypes: true}).flatMap(e => e.isDirectory() ? files(join(dir,e.name)) : e.name.endsWith('.mjs') ? [join(dir,e.name)] : []);
const result = { date: new Date().toISOString(), node: process.version, compilerSha256: createHash('sha256').update(readFileSync(beni)).digest('hex'), compilerBaseCommit: execFileSync('git', ['rev-parse', 'HEAD'], {encoding:'utf8'}).trim(), bytes: [], scripts: [] };
for (const platform of ['browser-tea', 'browser-direct']) {
  for (const release of [false,true]) {
    const out = join(work, platform + (release ? '-release' : '-dev'));
    run(['build', `--platform=${platform}`, '--no-cache', ...(release ? ['--release'] : ['--no-source-maps']), `--out=${out}`, 'examples/conduit/src']);
    const bytes = Buffer.concat(files(out).sort().map(f => readFileSync(f)));
    result.bytes.push({platform, release, raw: bytes.length, brotli11: brotliCompressSync(bytes, {params: {[constants.BROTLI_PARAM_QUALITY]: 11}}).length});
  }
}
result.analysis = run(['dump','--stage=writes','--platform=browser-direct','examples/conduit/src']);
const measured = join(work, 'counts');
rmSync(measured, {recursive:true, force:true});
cpSync(join(work,'browser-direct-dev'), measured, {recursive:true});
let probes = 0;
let handlers = 0;
for (const f of files(measured)) {
  let source = readFileSync(f,'utf8');
  source = source.replace(/^(\s*)if \(([^\n]*\.g(\d+)_\d+[^\n]*)\) \{/gm, (all, indent, cond, group) => {
    probes++;
    return `${indent}if (globalThis.__s6Active) globalThis.__s6Active.groups.push(${JSON.stringify(f.slice(measured.length + 1)+':'+source.slice(0, source.indexOf(all)).split('\n').length+':'+group)});\n${all}`;
  });
  if (f.endsWith('/Main.mjs')) {
    source = source.replace(/(  const (\$h[^\s=]+) = \([^\n]*\) => \{\n)([\s\S]*?)(^  \};)/gm, (_, start, name, body, end) => { handlers++; return `${start}    globalThis.__s6Active = {handler:${JSON.stringify(name)}, groups:[], patchAll:0};\n${body}    console.log('__s6_dispatch ' + JSON.stringify(globalThis.__s6Active));\n    globalThis.__s6Active = null;\n${end}`; });
    source = source.replace(/(const \$patchAll[^\s=]* = \(\) => \{)/g, '$1\n    if (globalThis.__s6Active) globalThis.__s6Active.patchAll++;');
  }
  writeFileSync(f, source);
}
if (!probes) throw new Error('No emitted group comparisons instrumented');
result.groupProbes = probes;
result.handlers = handlers;
for (const script of ['Reader','Editor','Tour']) {
  const steps = join(repo,`tests/corpus/browser/direct/Conduit${script}/_expected.steps`);
  const stdout = execFileSync('node',[join(repo,'tests/browser/driver.mjs'),`--dom=${join(repo,'tests/browser/happy-dom.mjs')}`,'--no-comments',join(measured,'_main.mjs'),steps],{encoding:'utf8',maxBuffer:1<<28});
  const dispatches = stdout.split('\n').filter(l=>l.startsWith('console.log: __s6_dispatch ')).map(l=>JSON.parse(l.slice('console.log: __s6_dispatch '.length)));
  if (!dispatches.length) throw new Error(`No dispatches for ${script}`);
  result.scripts.push({script, dispatches: dispatches.length, patchAll:dispatches.reduce((n,d)=>n+d.patchAll,0), rows:dispatches.map(d=>({...d, visitedGroups:d.groups.length}))});
}
result.criterion7 = {
  zeroWriteHandler: result.scripts.flatMap(s=>s.rows).filter(d=>d.handler.startsWith('$hClickedLink$Internal$')),
  fires: result.scripts.some(s=>s.rows.some(d=>d.handler.startsWith('$hClickedLink$Internal$') && d.visitedGroups>0)),
  mechanism: 'The root document value calls shared helpers and their value-kind patches on every handler. ClickedLink/Internal has an empty write set and zero predicted pairs, yet enters group comparisons. patchAll itself remains confined to ChangedUrl.'
};
console.log(JSON.stringify(result,null,2));
