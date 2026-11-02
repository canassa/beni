import fs from 'fs';
const dir = process.argv[2], base = process.argv[3], stage = process.argv[4];
const times = Object.fromEntries(fs.readFileSync(dir + '/times.txt', 'utf8').trim().split('\n').map(l => { const [k, rc, t] = l.split(' '); return [k, { rc: +rc, t: +t }]; }));
const keys = [...new Set(Object.keys(times).map(k => k.replace(/__[a-z0-9]+$/, '')))].sort();
const parse = (k) => {
  const txt = fs.existsSync(`${dir}/${k}.out`) ? fs.readFileSync(`${dir}/${k}.out`, 'utf8') : '';
  const v = new Map(), other = [];
  for (const l of txt.split('\n')) {
    const m = l.match(/^  (\d+:\d+ .*?): (accepted|rejected|pending)(.*)$/);
    if (m) { v.set(m[1] + '#' + ([...v.keys()].filter(x => x.startsWith(m[1] + '#')).length), { verdict: m[2], rest: m[3], line: l.trim() }); continue; }
    if (/^  (unchecked|limit) /.test(l)) other.push(l.trim());
  }
  return { v, other, txt };
};
const out = { a2r: [], r2a: [], gone: [], added: [], limits: [], crash: [], same: 0, fixtures: 0, cause: [] };
for (const k of keys) {
  out.fixtures++;
  const b = parse(k + '__' + base), s = parse(k + '__' + stage);
  const tb = times[k + '__' + base], ts = times[k + '__' + stage];
  if (ts.rc !== 0 && ts.rc !== tb.rc) out.crash.push(`${k}: rc ${tb.rc} -> ${ts.rc} ` + (fs.readFileSync(`${dir}/${k}__${stage}.err`, 'utf8').split('\n').find(l => /panic|error/.test(l)) || ''));
  for (const [key, x] of b.v) {
    const y = s.v.get(key);
    if (!y) { out.gone.push(`${k}: ${x.line}`); continue; }
    if (x.verdict === y.verdict) { out.same++; if (x.rest !== y.rest) out.cause.push(`${k}: ${x.line}  =>  ${y.verdict}${y.rest}`); continue; }
    (x.verdict === 'accepted' ? out.a2r : out.r2a).push(`${k}: ${x.line}  =>  ${y.verdict}${y.rest}`);
  }
  for (const [key, y] of s.v) if (!b.v.has(key)) out.added.push(`${k}: ${y.line}`);
  const ob = new Set(b.other), os = new Set(s.other);
  for (const l of b.other) if (!os.has(l)) out.limits.push(`${k}: - ${l}`);
  for (const l of s.other) if (!ob.has(l)) out.limits.push(`${k}: + ${l}`);
}
console.log(`stage ${stage}: fixtures ${out.fixtures}, same verdict ${out.same}, accept->refuse ${out.a2r.length}, refuse->accept ${out.r2a.length}, lines gone ${out.gone.length}, lines added ${out.added.length}, cause text changed ${out.cause.length}, unchecked/limit line changes ${out.limits.length}, crashes ${out.crash.length}`);
for (const s of ['crash', 'a2r', 'r2a', 'gone', 'added', 'limits', 'cause']) { if (out[s].length) { console.log(`--- ${s}`); for (const l of out[s]) console.log(l); } }
