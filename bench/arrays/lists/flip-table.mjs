// The flip's table (plans/list-arrays.md, slice 2's measurements): the shipped `beni` candidate
// against the E1tp prototype it ports, E1t, and the cons list, per cell of a results file.
//
//   node lists/flip-table.mjs [results/all-quick-node.jsonl]
import fs from 'node:fs';

const file = process.argv[2] ?? 'results/all-quick-node.jsonl';
const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const cands = ['beni', 'E1tp', 'E1t', 'cons'];
const cell = new Map();
for (const r of rows) {
  if (!cands.includes(r.impl) || (r.group !== 'list' && r.group !== 'ops')) continue;
  const k = `${r.group}|${r.style}|${r.op}|${r.n}`;
  if (!cell.has(k)) cell.set(k, {});
  cell.get(k)[r.impl] = r.med !== undefined ? r.med : r.overflow ? 'SO' : r.skipped ? 'skip' : r.crashed ? 'fail' : '?';
}
const fmt = (ns) => (typeof ns !== 'number' ? ns : ns >= 1e6 ? `${(ns / 1e6).toFixed(2)} ms` : `${(ns / 1e3).toFixed(1)} µs`);
const ratio = (a, b) => (typeof a === 'number' && typeof b === 'number' ? `${(a / b).toFixed(2)}×` : '—');
const out = [];
for (const [group, style, title] of [
  ['list', 'first', 'list scenarios, array-first code'],
  ['list', 'elm', 'list scenarios, Elm-style code'],
  ['ops', 'first', 'single operations, array-first code'],
  ['ops', 'elm', 'single operations, Elm-style code'],
]) {
  out.push('', `### ${title}`, '', '| cell | n | beni | E1tp | E1t | cons | beni ÷ E1tp | beni ÷ cons |', '|---|--:|--:|--:|--:|--:|--:|--:|');
  const keys = [...cell.keys()].filter((k) => k.startsWith(`${group}|${style}|`));
  for (const k of keys) {
    const [, , op, n] = k.split('|');
    const c = cell.get(k);
    out.push(`| ${op} | ${n} | ${cands.map((x) => fmt(c[x] ?? '—')).join(' | ')} | ${ratio(c.beni, c.E1tp)} | ${ratio(c.beni, c.cons)} |`);
  }
}
console.log(out.join('\n'));
