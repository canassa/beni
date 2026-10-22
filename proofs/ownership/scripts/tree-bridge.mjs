#!/usr/bin/env node
// The tree fragment's bridge: compare the oracle's verdict for every
// declaration of an export (`lake exe ownership tree-export --out=DIR`) with
// the shipping checker's (`beni dump --stage=ownership`). A declaration is
// rejected by the shipping checker when one of its demands is. Prints every
// divergence class with its count and first modules; exits 1 when any
// declaration diverges.
//
//   node scripts/tree-bridge.mjs --dir=DIR [--compiler=/abs/beni] [--show=5]
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

const flag = (name, dflt) => {
  const a = process.argv.find(x => x.startsWith(`--${name}=`));
  return a ? a.slice(name.length + 3) : dflt;
};
const dir = resolve(flag('dir', '../../zig-out/scratch/tree-export'));
const compiler = flag('compiler', resolve('../../zig-out/bin/beni'));
const show = Number(flag('show', '5'));

const manifest = readFileSync(resolve(dir, 'manifest.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l));
const dumped = spawnSync(compiler, ['dump', '--stage=ownership', '--platform=browser-direct', '--jobs=1', dir],
  { encoding: 'utf8', maxBuffer: 1 << 30 });
if (dumped.status !== 0) {
  console.error(dumped.stderr);
  throw Error(`dump failed with status ${dumped.status}`);
}
// module -> [{line, verdict, text}]
const demands = new Map();
let current = null;
for (const line of dumped.stdout.split('\n')) {
  const m = /^module (\S+)/.exec(line);
  if (m) { current = m[1]; demands.set(current, []); continue; }
  const d = /^  (\d+):(\d+) (.*): (accepted|rejected|pending)\b/.exec(line);
  if (d && current) demands.get(current).push({ line: Number(d[1]), verdict: d[4], text: line.trim() });
}
const classes = new Map();
let decls = 0, diverged = 0;
for (const { module, decls: ds } of manifest) {
  const ms = demands.get(module);
  if (!ms) throw Error(`no dump for module ${module}`);
  for (const d of ds) {
    decls++;
    const mine = ms.filter(x => x.line >= d.first && x.line <= d.last);
    const zig = mine.some(x => x.verdict !== 'accepted') ? 'rejected' : 'accepted';
    const lean = d.accepted ? 'accepted' : 'rejected';
    if (zig === lean) continue;
    diverged++;
    const key = `${d.name}: oracle ${lean}, zig ${zig}`;
    const c = classes.get(key) ?? { count: 0, examples: [] };
    c.count++;
    if (c.examples.length < show) c.examples.push(`${module} ${mine.map(x => x.text).join(' | ')}`);
    classes.set(key, c);
  }
}
console.log(`tree bridge: ${manifest.length} modules, ${decls} declarations, ${diverged} diverge`);
for (const [key, c] of [...classes].sort((a, b) => b[1].count - a[1].count)) {
  console.log(`  ${c.count} × ${key}`);
  for (const e of c.examples) console.log(`      ${e}`);
}
process.exit(diverged ? 1 : 0);
