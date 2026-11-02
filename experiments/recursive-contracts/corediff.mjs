import fs from 'fs';
const [a, b] = process.argv.slice(2).map(f => fs.readFileSync(f, 'utf8').split('\n'));
const parse = (ls) => { let mod = ''; const v = new Map(), o = new Set(); const seen = {};
  for (const l of ls) { const m0 = l.match(/^module (\S+)/); if (m0) { mod = m0[1]; continue; }
    const m = l.match(/^  (\d+:\d+ .*?): (accepted|rejected|pending)(.*)$/); if (m) { const k = mod + ' ' + m[1]; seen[k] = (seen[k] || 0) + 1; v.set(k + '#' + seen[k], m[2] + m[3]); continue; }
    if (/^  (unchecked|limit) /.test(l)) o.add(mod + ' ' + l.trim()); }
  return { v, o }; };
const A = parse(a), B = parse(b); let same = 0; const out = { a2r: [], r2a: [], gone: [], added: [] };
for (const [k, x] of A.v) { const y = B.v.get(k); if (y === undefined) { out.gone.push(k + ': ' + x); continue; } const xa = x.startsWith('accepted'), ya = y.startsWith('accepted'); if (xa === ya) same++; else (xa ? out.a2r : out.r2a).push(k + ': ' + x + ' => ' + y); }
for (const [k, y] of B.v) if (!A.v.has(k)) out.added.push(k + ': ' + y);
console.log(`same ${same}, a2r ${out.a2r.length}, r2a ${out.r2a.length}, gone ${out.gone.length}, added ${out.added.length}`);
for (const s of ['a2r', 'r2a', 'gone', 'added']) for (const l of out[s]) console.log(s + ' ' + l);
for (const l of A.o) if (!B.o.has(l)) console.log('- ' + l);
for (const l of B.o) if (!A.o.has(l)) console.log('+ ' + l);
