// handed-back.mjs <outdir> [filter]: a generator for callbacks run, then handed back (#2410).
// A callee runs a callback that writes what it captures, then hands the callback back to the caller,
// which runs it again or passes it on. Two runs of a capture writer are a stale capture: the sanitised
// build must refuse it (`once`) or print the same. Programs are
// `<runs>.<back>.<hop>.<use>.<writer>/Main.beni`. See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/handed-back.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;

const F = '(⊤ → List Int)';
// How the callee hands the callback back: its result type, the result built from `f`, and how the caller
// reads the callback `g` out of a result `x` (a binding line, or a case).
const BACKS = {
  dir: { T: F, mk: 'f', get: (x, k) => `g = ${x}\n${k}` },
  rec: { T: `{ run : ${F} }`, mk: '{ run = f }', get: (x, k) => `r = ${x}\ng = r.run\n${k}` },
  tup: { T: `Int × ${F}`, mk: '( 1, f )', get: (x, k) => `( _, g ) = ${x}\n${k}` },
  may: { T: `Maybe ${F}`, mk: 'Just f', get: (x, k) => `case ${x} of\n    Just g →\n${ind(k, 8)}\n\n    Nothing →\n        "none"` },
  ident: { T: F, mk: 'ident f', get: (x, k) => `g = ${x}\n${k}` },
  wrapd: { T: F, mk: 'λ⊤ → f ⊤', get: (x, k) => `g = ${x}\n${k}` },
};
// How many times the callee runs the callback before it hands it back. `zero` is the twin a perfect
// checker accepts when the caller runs it once.
const RUNS = { zero: '', once: '_ = f ⊤\n', ifone: 'xs = if List.length (f ⊤) > 99 then [ 1 ] else [ 2 ]\n_ = xs\n' };
// How the caller reaches the callee: directly, through `ident`, through a walked wrapper, or with the
// callback first handed through `ident`.
const HOPS = {
  direct: (a) => `back ${a}`,
  ident: (a) => `ident (back ${a})`,
  wrap: (a) => `wrap ${a}`,
  argid: (a) => `back (ident ${a})`,
};
// What the caller does with the callback it gets back.
const USES = {
  call: 'show (g ⊤)',
  apply: 'show (apply g)',
  idcall: 'show ((ident g) ⊤)',
  again: 'show (apply (runBack g))',
  none: '"n"',
  twice: '_ = g ⊤\nshow (g ⊤)',
};
// The callback: what it writes.
const WRITERS = {
  cap: { pre: 'k = [ n ]', arg: 'λ⊤ → List.push k 1' },
  loc: { pre: 'k = [ n ]\nw = λ⊤ → List.push k 1', arg: 'w' },
  via: { pre: 'k = [ n ]\np = λl → List.push l 1', arg: 'λ⊤ → p k' },
  recf: { pre: 'k = { l = [ n ] }', arg: 'λ⊤ → List.push k.l 1' },
  top: { pre: '', arg: '(mkw [ n ])' },
  ans: { pre: 'k = [ n ]\nq = λ⊤ → k', arg: 'λ⊤ → List.push (q ⊤) 1' },
};

function gen(runs, backName, hop, use, wr) {
  const B = BACKS[backName], W = WRITERS[wr];
  const decls = [
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('ident', 'a → a', 'f', 'f'),
    fn('apply', `${F} → List Int`, 'f', 'f ⊤'),
    fn('runBack', `${F} → ${F}`, 'f', '_ = f ⊤\nf'),
    fn('back', `${F} → ${B.T}`, 'f', RUNS[runs] + B.mk),
    fn('wrap', `${F} → ${B.T}`, 'f', 'back f'),
    ...(wr === 'top' ? [fn('mkw', `List Int → ${F}`, 'k', 'λ⊤ → List.push k 1')] : []),
  ];
  const body = use === 'none' ? `_ = ${HOPS[hop](W.arg)}\n"n"` : B.get(HOPS[hop](W.arg), USES[use]);
  const go = fn('go', 'Int → String', 'n', (W.pre ? W.pre + '\n' : '') + body);
  return ['import List\nimport Node exposing (Program)\nimport String\n', ...decls, go, 'main : Program\nmain = Node.print (go 0)\n'].join('\n\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const runs of Object.keys(RUNS)) for (const back of Object.keys(BACKS)) for (const hop of Object.keys(HOPS))
  for (const use of Object.keys(USES)) for (const wr of Object.keys(WRITERS)) {
    const name = `${runs}.${back}.${hop}.${use}.${wr}`;
    if (filter && !name.includes(filter)) continue;
    const d = path.join(out, name);
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'Main.beni'), gen(runs, back, hop, use, wr));
    list.push(path.resolve(d));
  }
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
