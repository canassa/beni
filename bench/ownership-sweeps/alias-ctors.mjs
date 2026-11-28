// alias-ctors.mjs <outdir> [filter]: research report 147, a record alias's constructor and a part of a
// construction at a step it does not have. A record alias's constructor makes the record its literal makes,
// with its object and its field slots, and matches one as a record pattern does (ownership-v3-kernel.md
// §11.2, §11.4); a construction read at a step its own place does not have (a tuple or a constructor read as a
// record through `Js.to`) is `unknown` there, never `none` (kernel §3.4). Before the report the constructor
// built a construction of its fields alone, its pattern projected by a constructor's step, and a missing step
// read as "no cell". Four families:
//
// - `built.<how>.<writer>.<read>`: a record `P n [ 1 ]` made by the constructor (directly, partially applied,
//   through a helper, from another module, generic, nested in another record, in a list, by `List.map` with
//   the constructor), written (an update, a helper's update, another module's), then its field `k` read
//   (`live`) or not (`dead`), by a field access, a constructor pattern, `==`, a closure.
// - `matched.<pattern>.<twin>`: a record whose two list fields are one list, matched by the constructor
//   (`case`, `let`, a parameter, a lambda, `as`, a generic alias, nested), one field pushed and the other
//   read (`live`) or not (`dead`).
// - `param.<pattern>.<twin>`: a function that matches its parameter by the constructor; the caller writes
//   the field the pattern binds, then calls it on the old record (`live`) or on the new one (`dead`).
// - `absent.<shape>.<twin>`: a test platform (`aliaspun`, written next to the programs) reads a value at
//   another type of the same JavaScript shape: a tuple or a constructor as a record, a record as a tuple, a
//   list of tuples as a list of records, below a type variable of an answer. A part is written (a push, an
//   update, a helper's update) and the value read after (`live`) or not (`dead`).
//
// The last part of a name is the twin kind (bench/ownership-sweeps/README.md).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/alias-ctors.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const progs = [];
const add = (name, main, other, platform) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, main, other, platform });
};
const indent = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${indent(body, 4)}\n`;

const OTHER = `import List


pub type alias Q =
    k : Int
    u : List Int


pub mk : Int → Q
mk n =
    Q n [ 1 ]


pub setK : Q → Q
setK r =
    { r | k = 5 }


pub kOf : Q → Int
kOf (Q k _) =
    k


pub uOf : Q → List Int
uOf (Q _ u) =
    u
`;

const DECLS = `type alias P =
    k : Int
    u : List Int


type alias G a =
    k : Int
    u : a


type alias N =
    inner : P
    m : Int


setK : P → P
setK r =
    { r | k = 5 }


kOf : P → Int
kOf (P k _) =
    k


mkP : Int → P
mkP n =
    P n [ 1 ]
`;

const prog = (imports, decls, go) => [`import Node exposing (Program)${imports}\n`, decls, fn('go', 'Int → String', 'n', go), 'main : Program\nmain = Node.print (go 0)\n'].join('\n\n');

// ---- built: made by the constructor, written, read ----------------------------------------------------------

// Each `how` names `a : P` (or `Q`, `G (List Int)`) and the type tag the writers and readers use.
const HOW = {
  direct: { make: 'a = P n [ 1 ]', ty: 'P' },
  partial: { make: 'f = P _ [ 1 ]\na = f n', ty: 'P' },
  helper: { make: 'a = mkP n', ty: 'P' },
  other: { make: 'a = Other.mk n', ty: 'Q' },
  otherCtor: { make: 'a = Other.Q n [ 1 ]', ty: 'Q' },
  generic: { make: 'a = G n [ 1 ]', ty: 'G' },
  nested: { make: 'o = N (P n [ 1 ]) 0\na = o.inner', ty: 'P' },
  inList: { make: 'a = case [ P n [ 1 ] ] of\n    [ x, …_ ] →\n        x\n\n    [] →\n        P 9 []', ty: 'P' },
  mapped: { make: 'a = case List.map [ n ] (P _ [ 1 ]) of\n    [ x, …_ ] →\n        x\n\n    [] →\n        P 9 []', ty: 'P' },
};
const WRITER = {
  upd: () => 'a2 = { a | k = 5 }',
  helper: (ty) => (ty === 'Q' ? 'a2 = Other.setK a' : ty === 'G' ? 'a2 = { a | k = 5 }' : 'a2 = setK a'),
};
const READ = {
  field: { live: 'a.k', dead: 'a2.k' },
  pattern: { live: (ty) => (ty === 'Q' ? 'Other.kOf a' : ty === 'G' ? 'case a of\n    G k _ →\n        k' : 'kOf a'), dead: () => 'a2.k' },
  eq: { live: 'if a == a2 then 1 else 0', dead: 'if a2 == a2 then 1 else 0' },
  closure: { live: 'g = λ⊤ → a.k\ng ⊤', dead: 'g = λ⊤ → a2.k\ng ⊤' },
};
for (const [how, h] of Object.entries(HOW)) for (const [wname, w] of Object.entries(WRITER)) for (const [rname, r] of Object.entries(READ)) for (const twin of ['live', 'dead']) {
  if (rname === 'eq' && h.ty === 'G') continue;
  const rd = typeof r[twin] === 'function' ? r[twin](h.ty) : r[twin];
  const body = `${h.make}\n${w(h.ty)}\nv =\n${indent(rd, 4)}\n"\${String.fromInt a2.k} \${String.fromInt v}"`;
  add(`built.${how}.${wname}.${rname}.${twin}`, prog(how.startsWith('other') ? '\nimport Other' : '', DECLS, body), how.startsWith('other') ? OTHER : null, null);
}

// ---- matched: a constructor pattern on a record whose two fields are one list ---------------------------------

const MATCH = {
  case: (read) => `case { k = 1, u = xs } of\n    P _ u →\n        w = List.push u 9\n        "\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
  casePair: (read) => `case { p = xs, q = xs } of\n    PQ u v →\n        w = List.push u 9\n        "\${String.fromInt (List.length w)} \${String.fromInt (${read === 'live' ? 'List.length v' : '0'})}"`,
  let: (read) => `(P _ u) = { k = 1, u = xs }\nw = List.push u 9\n"\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
  lambda: (read) => `f = λ(P _ u) → List.push u 9\nw = f { k = 1, u = xs }\n"\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
  as: (read) => `case { k = 1, u = xs } of\n    ((P _ u) as whole) →\n        w = List.push u 9\n        "\${String.fromInt (List.length w)} \${String.fromInt (${read})} \${String.fromInt whole.k}"`,
  generic: (read) => `case G 1 xs of\n    G _ u →\n        w = List.push u 9\n        "\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
  nested: (read) => `case N { k = 1, u = xs } 0 of\n    N (P _ u) _ →\n        w = List.push u 9\n        "\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
  builtCtor: (read) => `case P 1 xs of\n    P _ u →\n        w = List.push u 9\n        "\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
  other: (read) => `u = Other.uOf { k = 1, u = xs }\nw = List.push u 9\n"\${String.fromInt (List.length w)} \${String.fromInt (${read})}"`,
};
const PQ = `type alias PQ =\n    p : List Int\n    q : List Int\n`;
for (const [m, g] of Object.entries(MATCH)) for (const twin of ['live', 'dead']) {
  const read = m === 'casePair' ? twin : twin === 'live' ? 'List.length xs' : '0';
  add(`matched.${m}.${twin}`, prog(m === 'other' ? '\nimport Other' : '', `${DECLS}\n\n${PQ}`, `xs = [ n ]\n${g(read)}`), m === 'other' ? OTHER : null, null);
}

// ---- param: a function that matches its parameter by the constructor ----------------------------------------

const PARAM = {
  decl: { call: (r) => `kOf ${r}` },
  lambda: { call: (r) => `(λ(P k _) → k) ${r}` },
  local: { call: (r) => `kk ${r}`, pre: 'kk : P → Int\nkk (P k _) =\n    k\n' },
  other: { call: (r) => `Other.kOf ${r}` },
  maybe: { call: (r) => `case Just ${r} of\n    Just (P k _) →\n        k\n\n    Nothing →\n        0` },
};
for (const [p, d] of Object.entries(PARAM)) for (const twin of ['live', 'dead']) {
  const ty = p === 'other' ? 'Other.Q' : 'P';
  const r0 = p === 'other' ? 'Other.Q n [ 1 ]' : '{ k = n, u = [ 1 ] }';
  const target = twin === 'live' ? 'r0' : 'r1';
  const body = `r0 : ${ty}\nr0 = ${r0}\nr1 = { r0 | k = 5 }\n${d.pre ? `${d.pre}\n` : ''}v =\n${indent(d.call(target), 4)}\n"\${String.fromInt r1.k} \${String.fromInt v}"`;
  add(`param.${p}.${twin}`, prog(p === 'other' ? '\nimport Other' : '', DECLS, body), p === 'other' ? OTHER : null, null);
}

// ---- absent: a construction read at a step it does not have --------------------------------------------------

const platformDir = path.join(path.resolve(out), '_aliaspun');
const platformRel = path.relative(root, platformDir);
const punModule = `--! A sweep's platform: a value read at another type of the same JavaScript shape.

import Js


pub conv : a → b
conv v =
    Js.to (Js.from v)


pub convPair : a → b × Int
convPair v =
    ( Js.to (Js.from v), 1 )
`;
const PUN_DECLS = `type W
    = W Int (List Int)


type alias R =
    a : Int
    b : List Int


setA : R → R
setA r =
    { r | a = 5 }


setAI : { a : Int, b : Int } → { a : Int, b : Int }
setAI r =
    { r | a = 5 }


pushA : { a : List Int, b : List Int } → List Int
pushA r =
    List.push r.a 9
`;
// Each shape: what is made, the write, and what reads the made value after it (`live`) or not (`dead`).
const ABSENT = {
  tupleField: { make: 'xs = [ n ]\nt = ( xs, xs )\np : { a : List Int, b : List Int }\np = AliasPun.conv t', write: 'w = List.push p.a 9\nx = List.length w', live: 'List.length xs', dead: '0' },
  tupleHelperPush: { make: 'xs = [ n ]\nt = ( xs, [ 2 ] )\np : { a : List Int, b : List Int }\np = AliasPun.conv t', write: 'x = List.length (pushA p)', live: 'List.length xs', dead: '0' },
  tupleUpdate: { make: 't = ( n, [ 1 ] )\np : R\np = AliasPun.conv t', write: 'p2 = { p | a = 5 }\nx = p2.a', live: 'case t of\n    ( m, _ ) →\n        m', dead: '0' },
  tupleHelper: { make: 't = ( n, [ 1 ] )\np : R\np = AliasPun.conv t', write: 'x = (setA p).a', live: 'case t of\n    ( m, _ ) →\n        m', dead: '0' },
  tupleNumbers: { make: 't = ( n, 1 )\np : { a : Int, b : Int }\np = AliasPun.conv t', write: 'x = (setAI p).a', live: 'case t of\n    ( m, _ ) →\n        m', dead: '0' },
  ctorHelper: { make: 'w0 = W n [ 1 ]\np : R\np = AliasPun.conv w0', write: 'x = (setA p).a', live: 'case w0 of\n    W m _ →\n        m', dead: '0' },
  ctorUpdate: { make: 'w0 = W n [ 1 ]\np : R\np = AliasPun.conv w0', write: 'p2 = { p | a = 5 }\nx = p2.a', live: 'case w0 of\n    W m _ →\n        m', dead: '0' },
  recordAsTuple: { make: 'xs = [ n ]\nr = { a = xs, b = xs }\np : List Int × List Int\np = AliasPun.conv r', write: 'x = case p of\n    ( q, _ ) →\n        List.length (List.push q 9)', live: 'List.length r.b', dead: '0' },
  answerBelow: { make: 't = ( n, [ 1 ] )\npr : R × Int\npr = AliasPun.convPair t', write: 'x = case pr of\n    ( p, _ ) →\n        p2 = { p | a = 5 }\n        p2.a', live: 'case t of\n    ( m, _ ) →\n        m', dead: '0' },
  elements: { make: 'ts = [ ( n, 1 ) ]\nps : List { a : Int, b : Int }\nps = AliasPun.conv ts', write: 'x = case ps of\n    [ p, …_ ] →\n        (setAI p).a\n\n    [] →\n        0', live: 'case ts of\n    [ ( m, _ ), …_ ] →\n        m\n\n    [] →\n        0', dead: '0' },
};
for (const [s, d] of Object.entries(ABSENT)) for (const twin of ['live', 'dead']) {
  const body = `${d.make}\n${d.write}\nv =\n${indent(d[twin], 4)}\n"\${String.fromInt x} \${String.fromInt v}"`;
  add(`absent.${s}.${twin}`, prog('\nimport AliasPun', PUN_DECLS, body), null, platformRel);
}

// ---- write the programs ------------------------------------------------------------------------------------

fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "aliaspun", "platforms": ["node"], "reexports": ["Node"] }\n');
fs.writeFileSync(path.join(platformDir, 'AliasPun.beni'), punModule);
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  if (p.other) fs.writeFileSync(path.join(d, 'Other.beni'), p.other);
  if (p.platform) fs.writeFileSync(path.join(d, 'PLATFORM'), `${p.platform}\n`);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
