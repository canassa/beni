import fs from 'fs';
const d = '/home/canassa/.cache/beni-agents/contracts-s6d/scale/';
const rows = [];
for (const fam of ['Copies', 'Fields']) for (const n of [1, 2, 3, 4, 8]) for (const c of ['c2', 'c26', 'c86']) {
  const b = `${d}${fam}${n}Big.${c}`;
  if (!fs.existsSync(b + '.time')) continue;
  const tm = fs.readFileSync(b + '.time', 'utf8').trim().split('\n');
  const out = fs.existsSync(b + '.out') ? fs.readFileSync(b + '.out', 'utf8') : '';
  let tot = 0, gr = 0, all = 0, lim = (out.match(/^  limit /mg) || []).length;
  for (const l of out.split('\n')) { const m = l.match(/^  account (\S+): .*growth (\d+) of \d+, total (\d+)/); if (!m) continue; all += +m[3]; if (m[1].startsWith('removeMin')) { tot += +m[3]; gr += +m[2]; } }
  rows.push(`${fam} ${n} ${c}: removeMin* total ${tot}, growth ${gr}, all decls ${all}, limits ${lim}, time ${tm[0]}, ${tm[1] || ''}`);
}
console.log(rows.join('\n'));
