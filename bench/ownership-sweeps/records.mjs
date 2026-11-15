// records.mjs <outdir> [filter]: a generator for records written in place (research report 142).
// A program keeps a record `r0` in a holder, writes it (an update, a helper, a helper of another module,
// a callback), then reads the holder. In place the holder and the written record are one object: a
// read of a written field, of the record whole, an equality or an identity compare after the write sees
// the new value, so the checker must refuse it or the outputs must agree. Programs are
// `<holder>.<writer>.<read>.<twin>/Main.beni`: `live` when the read sees a field the writer wrote (or
// the whole record), `dead` when it reads only fields the writer leaves alone, or nothing. A refusal of
// a `dead` twin is a precision loss; a TRAP or DIFF of any is a soundness hole. See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/records.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;

// Where the old record stays: `pre` binds the holder after `r0` is made, `get` reads the record back
// out of it after the write.
const HOLDERS = {
  name: { pre: '', get: 'r0' },
  alias: { pre: 'h = r0', get: 'h' },
  tuple: { pre: 'h = ( r0, 1 )', get: 'fstOf h' },
  field: { pre: 'h = { inner = r0 }', get: 'h.inner' },
  ctor: { pre: 'h = Just r0', get: 'unJust h r0' },
  list: { pre: 'h = [ r0 ]', get: 'headOr h r0' },
  dict: { pre: 'h = Dict.fromList [ ( 1, r0 ) ]', get: 'Maybe.withDefault (Dict.get h 1) r0' },
  closure: { pre: 'h = λ⊤ → r0', get: 'h ⊤' },
  ident: { pre: 'h = ident r0', get: 'h' },
  pattern: { pre: '{ p } = r0\nh = p', get: 'withP r1 h' },
};

// How `r0` is written: the expression that answers the written record, and the fields it writes
// (`p.a`: the nested record's field, so `p` too).
const WRITERS = {
  upd: { e: '{ r0 | x = 10 }', w: ['x'] },
  two: { e: '{ r0 | x = 10, y = r0.y + 1 }', w: ['x', 'y'] },
  helper: { e: 'setX r0 10', w: ['x'] },
  other: { e: 'Other.setX r0 10', w: ['x'] },
  chain: { e: 'setX (setX r0 3) 10', w: ['x'] },
  nested: { e: '{ r0 | p = { (r0.p) | a = 9 } }', w: ['p', 'p.a'] },
  nhelper: { e: 'setPA r0 9', w: ['p', 'p.a'] },
  othernested: { e: 'Other.setPA r0 9', w: ['p', 'p.a'] },
  map: { e: 'headOr (List.map [ r0 ] λv → { v | x = 10 }) r0', w: ['x'] },
  lambda: { pre: 'wr = λv → { v | x = 10 }', e: 'wr r0', w: ['x'] },
  fold: { e: 'List.foldl [ 4, 6 ] r0 λi acc → { acc | x = acc.x + i }', w: ['x'] },
  copy: { e: '{ Record.copy r0 | x = 10 }', w: [] },
};

// What is read of the held record `g` after the write: the fields it reads (`*`: all of it).
const READS = {
  wx: { e: (g) => `String.fromInt (${g}).x`, r: ['x'] },
  wy: { e: (g) => `String.fromInt (${g}).y`, r: ['y'] },
  pa: { e: (g) => `String.fromInt (${g}).p.a`, r: ['p', 'p.a'] },
  whole: { e: (g) => `show (${g})`, r: ['*'] },
  eq: { e: (g) => `if ${g} == r1 then "eq" else "ne"`, r: ['*'] },
  none: { e: () => '"n"', r: [] },
};

const OTHER = `import Dict
import List


pub setX : { r | x : Int }, Int → { r | x : Int }
setX r n = { r | x = n }


pub setPA : { r | p : { a : Int, b : Int } }, Int → { r | p : { a : Int, b : Int } }
setPA r n = { r | p = { (r.p) | a = n } }
`;

function gen(holder, writer, read) {
  const H = HOLDERS[holder], W = WRITERS[writer], R = READS[read];
  const decls = [
    'type alias P =\n    a : Int\n    b : Int\n',
    'type alias R =\n    x : Int\n    y : Int\n    xs : List Int\n    p : P\n',
    fn('show', 'R → String', 'r', 'sep = ","\nxs = String.join (List.map r.xs String.fromInt) sep\n"${String.fromInt r.x}/${String.fromInt r.y}/${xs}/${String.fromInt r.p.a}"'),
    fn('setX', 'R, Int → R', 'r n', '{ r | x = n }'),
    fn('setPA', 'R, Int → R', 'r n', '{ r | p = { (r.p) | a = n } }'),
    fn('ident', 'a → a', 'v', 'v'),
    fn('fstOf', 'R × Int → R', '( v, _ )', 'v'),
    fn('unJust', 'Maybe R, R → R', 'm d', 'case m of\n    Just v →\n        v\n\n    Nothing →\n        d'),
    fn('headOr', 'List R, R → R', 'l d', 'case l of\n    [ v, …_ ] →\n        v\n\n    [] →\n        d'),
    fn('withP', 'R, P → R', 'r q', '{ Record.copy r | p = q }'),
  ];
  const lines = ['r0 = { x = n, y = 2, xs = [ 1 ], p = { a = 7, b = 8 } }'];
  if (H.pre) lines.push(H.pre);
  if (W.pre) lines.push(W.pre);
  lines.push(`r1 = ${W.e}`);
  lines.push(`a = ${R.e(H.get)}`);
  lines.push('"${show r1} ${a}"');
  const go = fn('go', 'Int → String', 'n', lines.join('\n'));
  return ['import Dict\nimport List\nimport Node exposing (Program)\nimport Other\nimport String\n', ...decls, go, 'main : Program\nmain = Node.print (go 0)\n'].join('\n\n');
}

// Whether the read sees a field the writer wrote. A holder that keeps only the nested record (`pattern`)
// sees only what is written below `p`.
function live(holder, writer, read) {
  const w = WRITERS[writer].w, r = READS[read].r;
  if (w.length === 0 || r.length === 0) return false;
  if (holder === 'pattern') return w.includes('p.a') && (r.includes('*') || r.includes('p.a'));
  return r.includes('*') || r.some((f) => w.includes(f));
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const holder of Object.keys(HOLDERS)) for (const writer of Object.keys(WRITERS)) for (const read of Object.keys(READS)) {
  const name = `${holder}.${writer}.${read}.${live(holder, writer, read) ? 'live' : 'dead'}`;
  if (filter && !name.includes(filter)) continue;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), gen(holder, writer, read));
  fs.writeFileSync(path.join(d, 'Other.beni'), OTHER);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
