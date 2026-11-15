// records.mjs <outdir> [filter]: a generator for records written in place (research report 142).
// A program keeps a record `r0` in a holder, writes it (an update, a helper, a helper of another module,
// a callback), then reads the holder. In place the holder and the written record are one object: a
// read of a written field, of the record whole, an equality or an identity compare after the write sees
// the new value, so the checker must refuse it or the outputs must agree. Programs are
// `<holder>.<writer>.<read>.<twin>/Main.beni`: `live` when the read sees a field the writer wrote (or
// the whole record), `dead` when it reads only fields the writer leaves alone, or nothing. A refusal of
// a `dead` twin is a precision loss; a TRAP or DIFF of any is a soundness hole. See README.md.
// The `aa.…` programs (research report 144) are the answered alias: a callee writes one operand and
// answers another that holds the same record (see `AA_PLACE`).
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

// The answered alias (research report 144): a callee writes one operand and answers another, and its
// caller hands it one record at both places. In place the answer is the written object; in the copying
// program it is the old one. The caller `fl` makes the record, calls, and answers what it gets, so no
// read of its own old name follows the call; `go` reads the answer. Programs are
// `aa.<placement>.<answer>.<write>.<read>.<twin>`: the placement is how one record reaches both
// operands, the answer how the callee answers the second, the write what it writes of the first.
const AA_PLACE = {
  args: { sig: 'R, V', params: 'u v', call: 'g r0 r0' },
  tuple: { sig: 'R × V', params: '( u, v )', call: 'g ( r0, r0 )' },
  field: { sig: 'Two V', params: 'h', bind: 'u = h.w\nv = h.k', call: 'g { w = r0, k = r0 }' },
  ctor: { sig: 'Pair V', params: 't', caseOf: ['t', 'Pair u v'], call: 'g (Pair r0 r0)' },
  maybe: { sig: 'Maybe R, V', params: 'm v', caseOf: ['m', 'Just u'], nothing: true, call: 'g (Just r0) r0' },
  dict: { sig: 'R, Dict Int V', params: 'u d', vexpr: 'd', vtype: 'Dict Int V', get: (x) => `Maybe.withDefault (Dict.get ${x} 1) dflt`, call: 'g r0 (Dict.singleton 1 r0)' },
  list: { sig: 'R, List V', params: 'u l', vexpr: 'l', vtype: 'List V', get: (x) => `headOr ${x} dflt`, call: 'g r0 [ r0 ]' },
  closure: { sig: 'R, (⊤ → V)', params: 'u c', vexpr: 'c', vtype: '(⊤ → V)', get: (x) => `${x} ⊤`, call: 'g r0 (λ⊤ → r0)' },
  generic: { sig: 'R, a', params: 'u v', vtype: 'a', generic: true, call: 'g r0 r0' },
  row: { sig: '{ r | x : Int }, { s | x : Int }', params: 'u v', vtype: '{ s | x : Int }', row: true, call: 'g r0 r0' },
  nested: { sig: 'R, P', params: 'u v', vtype: 'P', nested: true, call: 'g r0 r0.p' },
  copy: { sig: 'R, P', params: 'u v', vtype: 'P', nested: true, call: 'g (Record.copy r0) r0.p' },
  fnparam: { sig: 'R, V', params: 'u v', call: 'h r0 r0', viaParam: true },
  lambda: { sig: 'R, V', params: 'u v', call: 'g r0 r0', local: true },
  capture: { sig: 'R', params: 'u', vexpr: 'r0', call: 'g r0', local: true },
  capfn: { sig: 'R', params: 'u', vexpr: 'r0', call: 'g r0', local: 'fn' },
};
const AA_ANSWER = {
  direct: { t: (v) => v, e: (v) => v, get: (x) => x },
  closure: { t: (v) => `(⊤ → ${v})`, e: (v) => `λ⊤ → ${v}`, get: (x) => `(${x} ⊤)` },
  box: { t: (v) => `Box (${v})`, e: (v) => `Box ${v}`, get: (x) => `(unbox ${x})` },
  keep: { t: (v) => `Keep (${v})`, e: (v) => `{ old = ${v} }`, get: (x) => `(${x}).old` },
  ident: { t: (v) => v, e: (v) => `ident ${v}`, get: (x) => x },
};
const AA_WRITE = {
  upd: { flat: (u) => `{ ${u} | x = ${u}.x + 5 }`, nested: (u) => `{ ${u} | p = { (${u}.p) | a = ${u}.p.a + 5 } }` },
  helper: { flat: (u) => `setX ${u} (${u}.x + 5)`, nested: (u) => `setPA ${u} (${u}.p.a + 5)` },
  other: { flat: (u) => `Other.setX ${u} (${u}.x + 5)`, nested: (u) => `Other.setPA ${u} (${u}.p.a + 5)` },
};
// The reads of the answered record `v` (an `R`, or the nested `P`), and whether each sees the write.
const AA_READ = {
  wx: { flat: (v) => `String.fromInt (${v}).x`, nested: (v) => `String.fromInt (${v}).a`, live: true },
  wy: { flat: (v) => `String.fromInt (${v}).y`, nested: (v) => `String.fromInt (${v}).b`, live: false },
  whole: { flat: (v) => `show (${v})`, nested: (v) => `showP (${v})`, live: true },
  eq: { flat: (v) => `if ${v} == u then "eq" else "ne"`, nested: (v) => `if ${v} == u.p then "eq" else "ne"`, live: true },
  none: { flat: () => '"n"', nested: () => '"n"', live: false },
};

function genAnswered(place, answer, write, read) {
  const Pl = AA_PLACE[place], A = AA_ANSWER[answer], W = AA_WRITE[write], Rd = AA_READ[read];
  const nested = !!Pl.nested;
  const V = nested ? 'P' : 'R';
  const vtype = (Pl.vtype ?? 'V').replaceAll('V', V);
  const vexpr = Pl.vexpr ?? 'v';
  const wr = nested ? W.nested('u') : W.flat('u');
  const rtype = Pl.row ? '{ r | x : Int }' : 'R';
  const ans = `( ${wr}, ${A.e(vexpr)} )`;
  let body;
  if (Pl.caseOf) {
    body = `case ${Pl.caseOf[0]} of\n    ${Pl.caseOf[1]} →\n        ${ans}`;
    if (Pl.nothing) body += `\n\n    Nothing →\n        ( v, ${A.e('v')} )`;
  } else body = (Pl.bind ? `${Pl.bind}\n` : '') + ans;
  const sig = `${Pl.sig.replaceAll('V', V)} → ${rtype} × ${A.t(vtype)}`;
  const decls = [
    'type alias P =\n    a : Int\n    b : Int\n',
    'type alias R =\n    x : Int\n    y : Int\n    xs : List Int\n    p : P\n',
    'type alias Two v =\n    w : R\n    k : v\n',
    'type Pair v\n    = Pair R v\n',
    'type Box v\n    = Box v\n',
    'type alias Keep v =\n    old : v\n',
    fn('unbox', 'Box v → v', '(Box v)', 'v'),
    fn('show', 'R → String', 'r', 'sep = ","\nxs = String.join (List.map r.xs String.fromInt) sep\n"${String.fromInt r.x}/${String.fromInt r.y}/${xs}/${String.fromInt r.p.a}"'),
    fn('showP', 'P → String', 'q', '"${String.fromInt q.a}/${String.fromInt q.b}"'),
    fn('setX', 'R, Int → R', 'r n', '{ r | x = n }'),
    fn('setPA', 'R, Int → R', 'r n', '{ r | p = { (r.p) | a = n } }'),
    fn('ident', 'a → a', 'v', 'v'),
    fn('headOr', 'List v, v → v', 'l d', 'case l of\n    [ v, …_ ] →\n        v\n\n    [] →\n        d'),
    fn('mk', 'Int → R', 'n', '{ x = n, y = 2, xs = [ 1 ], p = { a = 7, b = 8 } }'),
  ];
  // The caller's type of the answer: the callee's, with a type variable or a row at the record the caller hands.
  const resT = `R × ${A.t(Pl.generic ? V : Pl.row ? 'R' : vtype)}`;
  const dflt = nested ? '{ a = 0, b = 0 }' : 'mk 0';
  if (Pl.local) {
    decls.push(fn('fl', `Int → ${resT}`, 'n', Pl.local === 'fn' ? `r0 = mk n\ng ${Pl.params} =\n    ${ans}\n${Pl.call}` : `r0 = mk n\ng = λ${Pl.params} → ${ans}\n${Pl.call}`));
  } else {
    decls.push(fn('g', sig, Pl.params, body));
    if (Pl.viaParam) decls.push(fn('fl', `Int, (${Pl.sig.replaceAll('V', V)} → ${rtype} × ${A.t(vtype)}) → ${resT}`, 'n h', `r0 = mk n\n${Pl.call}`));
    else decls.push(fn('fl', `Int → ${resT}`, 'n', `r0 = mk n\n${Pl.call}`));
  }
  const getV = (x) => (Pl.get ? Pl.get(A.get(x)) : A.get(x));
  const call = Pl.viaParam ? 'fl n g' : 'fl n';
  const readE = nested ? Rd.nested('v') : Rd.flat('v');
  decls.push(fn('go', 'Int → String', 'n', `case ${call} of\n    ( u, w ) →\n        dflt = ${dflt}\n        v = ${getV('w')}\n        got = ${readE}\n        "\${show u} \${got}"`));
  return ['import Dict exposing (Dict)\nimport List\nimport Node exposing (Program)\nimport Other\nimport String\n', ...decls, 'main : Program\nmain = Node.print (go 0)\n'].join('\n\n');
}

// A loop whose state keeps a snapshot of one of its records, then writes that record's field. `field`:
// the state is a record; `tuple`: a pair; `mutual`: two functions take turns.
function genLoop(kind, read) {
  const decls = ['type alias P =\n    a : Int\n    b : Int\n', 'type alias S =\n    cur : P\n    snap : P\n'];
  const rd = read === 'live' ? 'a' : 'b';
  if (kind === 'field') {
    decls.push(fn('loop', 'Int, S → S', 'k acc', 'if k > 2 then\n    acc\nelse if k == 1 then\n    loop (k + 1) { acc | snap = acc.cur }\nelse\n    loop (k + 1) { acc | cur = { (acc.cur) | a = acc.cur.a + 5 } }'));
    decls.push(fn('go', 'Int → String', 'n', `r = loop 1 { cur = { a = n, b = 0 }, snap = { a = 0, b = 0 } }\n"\${String.fromInt r.cur.a} \${String.fromInt r.snap.${rd}}"`));
  } else if (kind === 'tuple') {
    decls.push(fn('loop', 'Int, P × P → P × P', 'k st', 'case st of\n    ( c, s ) →\n        if k > 2 then\n            st\n        else if k == 1 then\n            loop (k + 1) ( c, c )\n        else\n            loop (k + 1) ( { c | a = c.a + 5 }, s )'));
    decls.push(fn('go', 'Int → String', 'n', `case loop 1 ( { a = n, b = 0 }, { a = 0, b = 0 } ) of\n    ( c, s ) →\n        "\${String.fromInt c.a} \${String.fromInt s.${rd}}"`));
  } else {
    decls.push(fn('la', 'Int, S → S', 'k acc', 'if k > 2 then\n    acc\nelse\n    lb (k + 1) { acc | snap = acc.cur }'));
    decls.push(fn('lb', 'Int, S → S', 'k acc', 'if k > 2 then\n    acc\nelse\n    la (k + 1) { acc | cur = { (acc.cur) | a = acc.cur.a + 5 } }'));
    decls.push(fn('go', 'Int → String', 'n', `r = la 1 { cur = { a = n, b = 0 }, snap = { a = 0, b = 0 } }\n"\${String.fromInt r.cur.a} \${String.fromInt r.snap.${rd}}"`));
  }
  return ['import Node exposing (Program)\nimport String\n', ...decls, 'main : Program\nmain = Node.print (go 0)\n'].join('\n\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
const emit = (name, main) => {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), main);
  fs.writeFileSync(path.join(d, 'Other.beni'), OTHER);
  list.push(path.resolve(d));
};
for (const place of Object.keys(AA_PLACE)) for (const answer of Object.keys(AA_ANSWER)) for (const write of Object.keys(AA_WRITE)) for (const read of Object.keys(AA_READ)) {
  if (AA_PLACE[place].row && write !== 'upd') continue;
  emit(`aa.${place}.${answer}.${write}.${read}.${AA_READ[read].live ? 'live' : 'dead'}`, genAnswered(place, answer, write, read));
}
for (const kind of ['field', 'tuple', 'mutual']) for (const read of ['live', 'dead']) emit(`aa.loop.${kind}.${read}`, genLoop(kind, read));
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
