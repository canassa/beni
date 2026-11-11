// recursive-levels.mjs <outdir> [filter]: a systematic (not random) generator for reads across recursive types.
// Enumerates shape × holder × reader × value sequence × live/dead, one program per directory
// `<outdir>/<shape>.<holder>.<reader>.<seq>.<live|dead>/Main.beni`, and writes `<outdir>/LIST`.
// Each program prints `a` (the reader's answer), plus `List.length k` when live: an in-place
// edit of the shared list `k` changes the second number. See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/recursive-levels.mjs <outdir> [filter]'); process.exit(2); }

const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
// A case expression of arms [[pat, body]]: multi-line layout.
const cs = (scrut, arms) => `case ${scrut} of\n` + arms.map(([p, b]) => ind(`${p} →\n${ind(b, 4)}`, 4)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;

// A lap: one trip round the cycle from τ back to τ. `mk(x)` builds it, `pat(p)` matches it
// with sub-pattern p at the inner τ (null: not nestable), `chain(i)` returns steps
// [{pat, next}] of a chained case binding the inner τ as the last `next`.
// A cut (a function of the holder `call`): `sig`, `body` (over param t0), `need` (laps the value
// must start with), `strip` (laps the result loses), `gen` (generic signature).
const SH = {};

SH.one = {
  decls: `type T\n    = L (List Int)\n    | W T\n    | E\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: { A: { mk: (x) => `W (${x})`, pat: (p) => `W (${p})`, chain: (i) => [{ pat: `W v${i}`, next: `v${i}` }] } },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['W u', 'w u'], ['E', '0']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['W u', 'W (rb u)'], ['E', 'E']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['W u', 'sz u'], ['E', '0']])),
  cuts: {},
};

SH.bin = {
  decls: `type T\n    = L (List Int)\n    | N T T\n    | E\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: {
    A: { mk: (x) => `N E (${x})`, pat: (p) => `N _ (${p})`, chain: (i) => [{ pat: `N _ v${i}`, next: `v${i}` }] },
    B: { mk: (x) => `N (${x}) E`, pat: (p) => `N (${p}) _`, chain: (i) => [{ pat: `N v${i} _`, next: `v${i}` }] },
  },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['N l r', 'w l + w r'], ['E', '0']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['N l r', 'N (rb l) (rb r)'], ['E', 'E']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['N l r', 'sz l + sz r'], ['E', '0']])),
  cuts: {
    sw: { sig: 'T → T', need: 'A', strip: 0, swapTo: 'B', body: cs('t0', [['N l r', 'N r l'], ['_', 'E']]) },
  },
};

SH.mid2 = {
  decls: `type T\n    = L (List Int)\n    | W U\n    | E\n\n\ntype U\n    = Z T\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: { A: { mk: (x) => `W (Z (${x}))`, pat: (p) => `W (Z (${p}))`, chain: (i) => [{ pat: `W (Z v${i})`, next: `v${i}` }] } },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['W u', 'wu u'], ['E', '0']])) + '\n' +
    fn('wu', 'U → Int', 'u', cs('u', [['Z t', 'w t']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['W u', 'W (rbu u)'], ['E', 'E']])) + '\n' +
    fn('rbu', 'U → U', 'u', cs('u', [['Z t', 'Z (rb t)']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['W (Z u)', 'sz u'], ['E', '0']])),
  cuts: {
    mid: { sig: 'T → T', need: 'AA', strip: 1, body: cs('t0', [['W (Z (W m))', 'W m'], ['_', 'E']]) },
    midw: { sig: 'T → T', need: 'A', strip: 0, body: cs('t0', [['W m', 'W m'], ['_', 'E']]) },
  },
};

SH.three = {
  decls: `type A\n    = AL (List Int)\n    | AB B\n    | AE\n\n\ntype B\n    = BC C\n    | BL (List Int)\n\n\ntype C\n    = CA A\n`,
  tau: 'A', leaf: (k) => `AL ${k}`, leafPat: (xs) => `AL ${xs}`, empty: 'AE',
  laps: { A: { mk: (x) => `AB (BC (CA (${x})))`, pat: (p) => `AB (BC (CA (${p})))`, chain: (i) => [{ pat: `AB (BC (CA v${i}))`, next: `v${i}` }] } },
  fns: fn('w', 'A → Int', 't', cs('t', [['AL xs', 'List.length (List.push xs 1)'], ['AB b', 'wb b'], ['AE', '0']])) + '\n' +
    fn('wb', 'B → Int', 'b', cs('b', [['BC c', 'wc c'], ['BL xs', 'List.length (List.push xs 1)']])) + '\n' +
    fn('wc', 'C → Int', 'c', cs('c', [['CA a', 'w a']])) + '\n' +
    fn('rb', 'A → A', 't', cs('t', [['AL xs', 'AL (List.push xs 1)'], ['AB b', 'AB (rbb b)'], ['AE', 'AE']])) + '\n' +
    fn('rbb', 'B → B', 'b', cs('b', [['BC (CA a)', 'BC (CA (rb a))'], ['BL xs', 'BL (List.push xs 1)']])) + '\n' +
    fn('sz', 'A → Int', 't', cs('t', [['AL xs', 'List.length xs'], ['AB (BC (CA a))', 'sz a'], ['AB (BL xs)', 'List.length xs'], ['AE', '0']])),
  cuts: {
    mid: { sig: 'A → A', need: 'AA', strip: 1, body: cs('t0', [['AB (BC (CA (AB m)))', 'AB m'], ['_', 'AE']]) },
    midc: { sig: 'A → A', need: 'AA', strip: 1, body: cs('t0', [['AB (BC (CA (AB (BC m))))', 'AB (BC m)'], ['_', 'AE']]) },
  },
};

SH.gr = {
  decls: `type G a\n    = GL a\n    | GP (G a) Int\n    | GZ (List Int)\n\n\ntype R\n    = RL (List Int)\n    | RW (G R)\n`,
  tau: 'G R', leaf: (k) => `GL (RL ${k})`, leafPat: (xs) => `GL (RL ${xs})`, empty: 'GZ []',
  laps: {
    A: { mk: (x) => `GL (RW (${x}))`, pat: (p) => `GL (RW (${p}))`, chain: (i) => [{ pat: `GL (RW v${i})`, next: `v${i}` }] },
    B: { mk: (x) => `GP (${x}) 0`, pat: (p) => `GP (${p}) _`, chain: (i) => [{ pat: `GP v${i} _`, next: `v${i}` }] },
  },
  fns: fn('w', 'G R → Int', 't', cs('t', [['GL r', 'wr r'], ['GP u _', 'w u'], ['GZ xs', 'List.length (List.push xs 1)']])) + '\n' +
    fn('wr', 'R → Int', 'r', cs('r', [['RL xs', 'List.length (List.push xs 1)'], ['RW g', 'w g']])) + '\n' +
    fn('rb', 'G R → G R', 't', cs('t', [['GL r', 'GL (rbr r)'], ['GP u n', 'GP (rb u) n'], ['GZ xs', 'GZ (List.push xs 1)']])) + '\n' +
    fn('rbr', 'R → R', 'r', cs('r', [['RL xs', 'RL (List.push xs 1)'], ['RW g', 'RW (rb g)']])) + '\n' +
    fn('sz', 'G R → Int', 't', cs('t', [['GL (RL xs)', 'List.length xs'], ['GL (RW g)', 'sz g'], ['GP u _', 'sz u'], ['GZ xs', 'List.length xs']])),
  cuts: {
    gs: { sig: 'G a → G a', gen: true, need: 'B', strip: 1, body: cs('t0', [['GP u _', 'u'], ['_', 't0']]) },
    gr: { sig: 'G a → G a', gen: true, need: 'BA', strip: 0, body: cs('t0', [['GP (GL m) _', 'GP (GL m) 0'], ['_', 't0']]) },
    gl: { sig: 'G a → G a', gen: true, need: 'A', strip: 0, body: cs('t0', [['GL m', 'GL m'], ['_', 't0']]) },
    mid: { sig: 'G R → G R', need: 'AA', strip: 1, body: cs('t0', [['GL (RW (GL m))', 'GL m'], ['_', 'GZ []']]) },
    pgl: { sig: 'G a → G a', gen: true, need: 'BA', strip: 1, body: cs('t0', [['GP (GL r) _', 'GL r'], ['_', 't0']]) },
    midb: { sig: 'G R → G R', need: 'AB', strip: 1, body: cs('t0', [['GL (RW (GP m _))', 'm'], ['_', 'GZ []']]) },
  },
};

SH.mayb = {
  decls: `type T\n    = L (List Int)\n    | W (Maybe T)\n    | E\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: { A: { mk: (x) => `W (Just (${x}))`, pat: (p) => `W (Just (${p}))`, chain: (i) => [{ pat: `W (Just v${i})`, next: `v${i}` }] } },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['W (Just u)', 'w u'], ['_', '0']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['W mu', 'W (Maybe.map mu rb)'], ['E', 'E']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['W (Just u)', 'sz u'], ['_', '0']])),
  cuts: {
    mid: { sig: 'T → T', need: 'AA', strip: 1, body: cs('t0', [['W (Just (W m))', 'W m'], ['_', 'E']]) },
    gj: { sig: 'T → T', need: 'A', strip: 0, body: cs('t0', [['W m', 'W (jm m)'], ['_', 'E']]), extra: fn('jm', 'Maybe a → Maybe a', 'x', cs('x', [['Just y', 'Just y'], ['Nothing', 'Nothing']])) },
  },
};

SH.listH = {
  decls: `type T\n    = L (List Int)\n    | W (List T)\n    | E\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: { A: { mk: (x) => `W [ E, ${x} ]`, pat: (p) => `W [ _, ${p} ]`, chain: (i) => [{ pat: `W [ _, v${i} ]`, next: `v${i}` }],
    rest: (i) => [{ pat: `W [ _, …r${i} ]`, next: `r${i}` }, { pat: `[ v${i} ]`, next: `v${i}` }] } },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['W ts', 'List.foldl ts 0 λu n → n + w u'], ['E', '0']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['W ts', 'W (List.map ts rb)'], ['E', 'E']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['W ts', 'List.foldl ts 0 λu n → n + sz u'], ['E', '0']])),
  cuts: {
    mid: { sig: 'T → T', need: 'AA', strip: 1, body: cs('t0', [['W [ _, W m ]', 'W m'], ['_', 'E']]) },
    rest: { sig: 'T → T', need: 'A', strip: 0, body: cs('t0', [['W [ hd, …tl ]', 'W [ hd, …tl ]'], ['_', 'E']]) },
  },
};

SH.tupH = {
  decls: `type T\n    = L (List Int)\n    | W (T × Int)\n    | E\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: { A: { mk: (x) => `W ( ${x}, 0 )`, pat: (p) => `W ( ${p}, _ )`, chain: (i) => [{ pat: `W ( v${i}, _ )`, next: `v${i}` }] } },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['W ( u, _ )', 'w u'], ['E', '0']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['W ( u, n )', 'W ( rb u, n )'], ['E', 'E']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['W ( u, _ )', 'sz u'], ['E', '0']])),
  cuts: {
    mid: { sig: 'T → T', need: 'AA', strip: 1, body: cs('t0', [['W ( W m, _ )', 'W m'], ['_', 'E']]) },
  },
};

SH.recH = {
  decls: `type T\n    = L (List Int)\n    | W { n : T, c : Int }\n    | E\n`,
  tau: 'T', leaf: (k) => `L ${k}`, leafPat: (xs) => `L ${xs}`, empty: 'E',
  laps: { A: { mk: (x) => `W { n = ${x}, c = 0 }`, pat: null, chain: (i) => [{ pat: `W r${i}`, next: `r${i}.n` }] } },
  fns: fn('w', 'T → Int', 't', cs('t', [['L xs', 'List.length (List.push xs 1)'], ['W r', 'w r.n'], ['E', '0']])) + '\n' +
    fn('rb', 'T → T', 't', cs('t', [['L xs', 'L (List.push xs 1)'], ['W r', 'W { r | n = rb r.n }'], ['E', 'E']])) + '\n' +
    fn('sz', 'T → Int', 't', cs('t', [['L xs', 'List.length xs'], ['W r', 'sz r.n'], ['E', '0']])),
  cuts: {
    mid: { sig: 'T → T', need: 'AA', strip: 1, body: cs('t0', [['W r', cs('r.n', [['W q', 'W q'], ['_', 'E']])], ['_', 'E']]) },
    upd: { sig: 'T → T', need: 'A', strip: 0, body: cs('t0', [['W r', 'W { r | c = 1 }'], ['_', 'E']]) },
  },
};

SH.fam = {
  decls: `type A a\n    = AL a\n    | AB (B a)\n    | AE\n\n\ntype B a\n    = BA (A a)\n    | BF (A (List a))\n`,
  tau: 'A (List Int)', leaf: (k) => `AL ${k}`, leafPat: (xs) => `AL ${xs}`, empty: 'AE',
  laps: { A: { mk: (x) => `AB (BA (${x}))`, pat: (p) => `AB (BA (${p}))`, chain: (i) => [{ pat: `AB (BA v${i})`, next: `v${i}` }] } },
  fns: fn('w', 'A (List Int) → Int', 't', cs('t', [['AL xs', 'List.length (List.push xs 1)'], ['AB (BA u)', 'w u'], ['_', '0']])) + '\n' +
    fn('rb', 'A (List Int) → A (List Int)', 't', cs('t', [['AL xs', 'AL (List.push xs 1)'], ['AB (BA u)', 'AB (BA (rb u))'], ['_', 't']])) + '\n' +
    fn('sz', 'A (List Int) → Int', 't', cs('t', [['AL xs', 'List.length xs'], ['AB (BA u)', 'sz u'], ['_', '0']])),
  cuts: {
    gs: { sig: 'A a → A a', gen: true, need: 'A', strip: 1, body: cs('t0', [['AB (BA m)', 'm'], ['_', 't0']]) },
    gmid: { sig: 'A a → A a', gen: true, need: 'AA', strip: 1, body: cs('t0', [['AB (BA (AB m))', 'AB m'], ['_', 't0']]) },
    grw: { sig: 'A a → A a', gen: true, need: 'A', strip: 0, body: cs('t0', [['AB (BA m)', 'AB (BA m)'], ['_', 't0']]) },
  },
};

// The point reader of a value whose laps are `seq`: nested patterns, or a chain of cases.
function pointNested(sh, seq) {
  let p = sh.leafPat('xs');
  for (let i = seq.length - 1; i >= 0; i--) p = sh.laps[seq[i]].pat(p);
  return fn('rd', `${sh.tau} → Int`, 't', cs('t', [[p, 'List.length (List.push xs 1)'], ['_', '0']]));
}
function pointChain(sh, seq, restLeaf, restLap) {
  const steps = [];
  seq.split('').forEach((c, i) => steps.push(...((restLap && sh.laps[c].rest) ? sh.laps[c].rest(i) : sh.laps[c].chain(i))));
  const leaf = restLeaf ? [sh.leafPat('[ _, …xs ]'), 'List.length (List.push xs 1)'] : [sh.leafPat('xs'), 'List.length (List.push xs 1)'];
  let body = null;
  for (let i = steps.length; i >= 0; i--) {
    const scrut = i === 0 ? 't' : steps[i - 1].next;
    body = i === steps.length ? cs(scrut, [leaf, ['_', '0']]) : cs(scrut, [[steps[i].pat, body], ['_', '0']]);
  }
  return fn(restLeaf || restLap ? 'rr' : 'rc', `${sh.tau} → Int`, 't', body);
}
const build = (sh, seq, k) => seq.split('').reduceRight((acc, c) => sh.laps[c].mk(acc), sh.leaf(k));

const HOLDERS = ['local', 'param', 'call', 'gcall', 'closure', 'fold', 'field', 'nest', 'cb', 'lnest'];
const MODES = ['live', 'livev', 'dead'];
const READERS = ['point', 'chain', 'deep', 'rebuild', 'part', 'rest'];

function seqsOf(sh) {
  const ls = Object.keys(sh.laps), r = [];
  const go = (s) => { if (s.length) r.push(s); if (s.length < 3) for (const l of ls) go(s + l); };
  go('');
  return r;
}

// The shape's helpers a program uses: `w*` for a deep read, `rb*` for a rebuild, `sz` to
// count. Each helper is checked too (--ownership-everywhere), so an unused one that is
// refused would poison every program of the shape.
function helpers(sh, need) {
  return sh.fns.split(/\n(?=\w+ : )/).filter((f) => {
    const n = f.match(/^(\w+) :/)[1];
    return (n.startsWith('rb') && need.rb) || (n === 'sz' && need.sz) || (n.startsWith('w') && need.w);
  }).map((f) => f.trimEnd() + '\n').join('\n\n');
}
function program(sname, sh, holder, cut, reader, seq, live) {
  // `seq`: the laps the reader sees; the value the holder builds starts with the cut's need.
  let vseq = seq, rseq = seq, cutDef = '';
  if (holder === 'lnest') {
    const c = sh.cuts[cut];
    vseq = c.need + seq;
    rseq = vseq.slice(c.strip);
    if (c.swapTo) rseq = c.swapTo + rseq.slice(1);
    cutDef = fn('cut', `${sh.tau} → ${sh.tau}`, 't0', cs('t0', [[vseq.split('').reduceRight((p, l) => sh.laps[l].pat(p), sh.leafPat('xs')), build(sh, vseq, 'xs')], ['_', sh.empty]])) + '\n' +
      fn('outer', `${sh.tau} → ${sh.tau}`, 't0', c.body.replace(/^case t0 of/, 'case cut t0 of')) + '\n' + (c.extra ? c.extra + '\n' : '');
  } else if (holder === 'call' || (holder === 'nest' && cut)) {
    // `lit`: the cut matches the whole value down to its list and builds it again (#2359's `hc`).
    const c = cut === 'lit' ? { sig: `${sh.tau} → ${sh.tau}`, need: '', strip: 0,
      body: cs('t0', [[seq.split('').reduceRight((p, l) => sh.laps[l].pat(p), sh.leafPat('xs')), build(sh, seq, 'xs')], ['_', sh.empty]]) } : sh.cuts[cut];
    vseq = c.need + seq;
    // The reader sees: the need minus the strip, rest unchanged; a swap renames the first lap.
    rseq = vseq.slice(c.strip);
    if (c.swapTo) rseq = c.swapTo + rseq.slice(1);
    cutDef = fn('cut', c.sig, 't0', c.body) + '\n' + (c.extra ? c.extra + '\n' : '');
  }
  let nestDef = '';
  if (holder === 'nest') {
    // `outer` returns a part of a call's result (or of its parameter, with no cut): the
    // read-off of a result below a call's slot (ReadOff.describeBelow, #2359).
    if (rseq.length < 2) return null;
    const st = sh.laps[rseq[0]].chain('o')[0];
    nestDef = fn('outer', `${sh.tau} → ${sh.tau}`, 't', cs(cut ? 'cut t' : 't', [[st.pat, st.next], ['_', sh.empty]]));
    rseq = rseq.slice(1);
  }
  let rd, use;
  switch (reader) {
    case 'point': if (!Object.values(sh.laps).every((l) => l.pat)) return null; rd = pointNested(sh, rseq); use = (x) => `rd (${x})`; break;
    case 'chain': rd = pointChain(sh, rseq, false, false); use = (x) => `rc (${x})`; break;
    case 'deep': rd = ''; use = (x) => `w (${x})`; break;
    case 'rebuild': rd = ''; use = (x) => `sz (rb (${x}))`; break;
    case 'part': {
      // `part` strips the first lap by a call, then a point read of the rest.
      const first = rseq[0];
      if (rseq.length < 1) return null;
      const st = sh.laps[first].chain('p');
      const pb = cs('t', [[st[0].pat, st[0].next], ['_', sh.empty]]);
      rd = fn('part', `${sh.tau} → ${sh.tau}`, 't', pb) + '\n' + pointChain(sh, rseq.slice(1), false, false);
      use = (x) => `rc (part (${x}))`;
      break;
    }
    case 'rest': {
      const restLap = Object.values(sh.laps).some((l) => l.rest);
      rd = pointChain(sh, rseq, !restLap, restLap); use = (x) => `rr (${x})`; break;
    }
  }
  const k = 'k';
  const val = (kk) => build(sh, vseq, kk);
  let main, extra = '';
  const tailOf = (orig, kk) => (live === 'live' ? ` + List.length ${kk}` : live === 'livev' ? ` + sz (${orig})` : '');
  const tail = tailOf('v', 'k');
  const pr = (e) => `    Node.print (String.fromInt (${e}))`;
  switch (holder) {
    case 'local': main = [`    v = ${val(k)}`, `    a = ${use('v')}`, pr('a' + tail)]; break;
    case 'param':
      extra = fn('outer', 'List Int → Int', 'k0', `v = ${val('k0')}\na = ${use('v')}\na${tailOf('v', 'k0')}`);
      main = [pr('outer k')];
      break;
    case 'call': main = [`    v = cut (${val(k)})`, `    a = ${use('v')}`, pr('a' + tail)]; break;
    case 'gcall':
      extra = fn('pass', 'a, Int → a', 'x _', 'x');
      main = [`    v = pass (${val(k)}) 0`, `    a = ${use('v')}`, pr('a' + tail)]; break;
    case 'closure': main = [`    v = ${val(k)}`, '    c = λu → v', `    a = ${use('c 0')}`, pr('a' + tailOf('c 1', 'k'))]; break;
    case 'fold': main = [`    v = List.foldl [ 1 ] (${val(k)}) λ_ b → b`, `    a = ${use('v')}`, pr('a' + tail)]; break;
    case 'field': main = [`    r = { t = ${val(k)}, c = 0 }`, `    a = ${use('r.t')}`, pr('a' + tailOf('r.t', 'k'))]; break;
    case 'nest': extra = nestDef; main = [`    v = outer (${val(k)})`, `    a = ${use('v')}`, pr('a' + tail)]; break;
    case 'lnest': main = [`    v = outer (${val(k)})`, `    a = ${use('v')}`, pr('a' + tail)]; break;
    case 'cb':
      extra = fn('app', '(a → b), a → b', 'f x', 'f x');
      main = [`    v = ${val(k)}`, `    a = app (λx → ${use('x')}) v`, pr('a' + tail)]; break;
  }
  const fns = helpers(sh, { w: reader === 'deep', rb: reader === 'rebuild', sz: reader === 'rebuild' || live === 'livev' });
  return `import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n\n\n${sh.decls}\n\n${fns ? fns + '\n\n' : ''}${rd ? rd + '\n\n' : ''}${cutDef ? cutDef + '\n' : ''}${extra ? extra + '\n\n' : ''}main : Program\nmain =\n    k = [ 1, 2 ]\n${main.join('\n')}\n`;
}

const list = [];
fs.mkdirSync(out, { recursive: true });
for (const [sname, sh] of Object.entries(SH)) {
  for (const holder of HOLDERS) {
    const cuts = holder === 'lnest' ? (sh.laps.A.pat ? Object.keys(sh.cuts) : []) : holder === 'call' ? [...Object.keys(sh.cuts), ...(sh.laps.A.pat ? ['lit'] : [])] : holder === 'nest' ? ['', ...Object.keys(sh.cuts), ...(sh.laps.A.pat ? ['lit'] : [])] : [''];
    for (const cut of cuts) for (const reader of READERS) for (const seq of seqsOf(sh)) for (const live of MODES) {
      // Keep the enumeration small where laps multiply: depth 3 only for one-lap shapes and
      // for sequences that end in a middle lap.
      const src = program(sname, sh, holder, cut, reader, seq, live);
      if (!src) continue;
      const name = `${sname}.${holder}${cut ? '-' + cut : ''}.${reader}.${seq}.${live}`;
      if (filter && !name.includes(filter)) continue;
      const d = path.join(out, name);
      fs.mkdirSync(d, { recursive: true });
      fs.writeFileSync(path.join(d, 'Main.beni'), src);
      list.push(d);
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
