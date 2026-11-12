// blind3.mjs <outdir> [filter]: research report 115, a third blind test of the prototype (`--ownership=v3`).
// It was written from the code of `src/own3/` alone, without the reports and generators of the first two
// blind tests. Seven families:
//
// - `answer`: a callee calls a function parameter once and puts the answer at two places of its result (a
//   pair, a record, a `Maybe` and the value, a list, a pair one level down). The caller writes one place and
//   reads the other. Callbacks: a lambda that makes a list, one that makes it from an argument, a named
//   function that makes it, and two controls (a lambda that answers a captured list, a callee that makes the
//   list itself). Callees: generic, monomorphic, and a local function.
// - `supply`: a callee hands a list that it made to a function parameter, which answers its parameter (or a
//   new list, the control), and puts the answer and the list, or two answers, in a pair.
// - `handon`: a callee calls `g` once (or makes a list), hands the list to `h`, and answers it. `h` keeps it in a cell,
//   writes it, or reads it. The caller writes the answer and reads the cell.
// - `compare`: a type's `eq` or `compare` writes its operand, or keeps it in a cell, or only reads it.
//   It is public or private, annotated or not, and is reached by an operator, a dot call, or as the
//   evidence of `==` on a list.
// - `sortwith`: the comparator of `List.sortWith` keeps an element in a cell, or only reads it. The caller
//   then writes that element.
// - `dict`: one list at two places of a `Dict`, or in a `Dict` and a local, then `Dict.update` writes it.
// - `front`: a prepend `[ item, …rest ]` whose item is a literal (`[]`, a tuple): the item is a new object,
//   so the result never re-uses the array of `rest`.
//
// Programs are `<family>.<…>.<twin>/Main.beni`; the twin is `live` (a read after the write sees the old
// value: the checker must refuse it), `dead` (the same shape, safe) or `none` (a read after the write that
// sees no change: also safe). See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind3.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const HEAD = 'import Dict exposing (Dict)\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport Ref exposing (Ref)\nimport String\n';
const HELPERS = `ints : List Int → String
ints xs =
    String.join (List.map xs String.fromInt) ","`;
const program = (decls, body) =>
  [HEAD, HELPERS, ...decls, `go : Int → String\ngo n =\n${ind(body, 4)}`, 'main : Program\nmain =\n    Node.print (go 0)\n'].join('\n\n\n');
const programs = [];
const add = (name, src) => { if (!filter || name.includes(filter)) programs.push([name, src]); };

// ---- answer ----------------------------------------------------------------------------------------------
// Holders: the type of the result over `a`, how the callee makes it from `x`, and how the caller takes the
// two places `p0` and `p1` from `r` around the lines `k`.
const HOLDERS = {
  pair: { T: (a) => `${a} × ${a}`, mk: 'x = g ⊤\n( x, x )', parts: (k) => `p0 = r.0\np1 = r.1\n${k}` },
  rec: { T: (a) => `{ a : ${a}, b : ${a} }`, mk: 'x = g ⊤\n{ a = x, b = x }', parts: (k) => `p0 = r.a\np1 = r.b\n${k}` },
  maybe: { T: (a) => `Maybe ${a} × ${a}`, mk: 'x = g ⊤\n( Just x, x )',
    parts: (k) => `p1 = r.1\ncase r.0 of\n    Just p0 →\n${ind(k, 8)}\n\n    Nothing →\n        "-"` },
  list: { T: (a) => `List ${a}`, mk: 'x = g ⊤\n[ x, x ]', parts: (k) => `case r of\n    [ p0, p1 ] →\n${ind(k, 8)}\n\n    _ →\n        "-"` },
  deep: { T: (a) => `(${a} × Int) × ${a}`, mk: 'x = g ⊤\n( ( x, 1 ), x )', parts: (k) => `p0 = r.0.0\np1 = r.1\n${k}` },
};
// Callbacks: the argument the caller hands, and whether it makes a new list each call (`fresh`).
const CALLBACKS = {
  lam: 'λ_ → [ n, 1 ]',
  arg: 'λ_ → List.repeat 2 n',
  named: 'fresh',
  cap: 'λ_ → c',           // control: a captured list, `shared` for the callee's answer
};
// Callees: generic, monomorphic, and a local function of `go`.
const CALLEES = ['generic', 'mono', 'local'];
const ANSWER_USES = {
  live: 'w = List.set p0 0 9\n"${ints w} ${ints p1}"',
  back: 'w = List.set p1 0 9\n"${ints w} ${ints p0}"',
  dead: 'w = List.set p0 0 9\n"${ints w}"',
};
for (const [hn, H] of Object.entries(HOLDERS)) for (const [cn, cb] of Object.entries(CALLBACKS)) for (const callee of CALLEES) for (const [un, use] of Object.entries(ANSWER_USES)) {
  const a = callee === 'mono' ? '(List Int)' : 'a';
  const sig = `(⊤ → ${callee === 'mono' ? 'List Int' : 'a'}) → ${H.T(a)}`;
  const decls = ['fresh : ⊤ → List Int\nfresh _ =\n    [ 7, 1 ]'];
  const lines = ['c = [ n, 2 ]'];
  if (callee === 'local') lines.push(`twoOf g =\n${ind(H.mk, 4)}`);
  else decls.push(`twoOf : ${sig}\ntwoOf g =\n${ind(H.mk, 4)}`);
  lines.push(`r = twoOf (${cb})`, H.parts(use));
  add(`answer.${hn}.${cn}.${callee}.${un === 'dead' ? 'dead' : un === 'back' ? 'back.live' : 'live'}`, program(decls, lines.join('\n')));
}
// The control where the callee makes the list itself (`also`).
for (const [un, use] of Object.entries(ANSWER_USES)) {
  add(`answer.pair.self.generic.${un === 'dead' ? 'dead' : un === 'back' ? 'back.live' : 'live'}`,
    program(['twoOf : ⊤ → List Int × List Int\ntwoOf _ =\n    x = [ 3, 1 ]\n    ( x, x )'], `r = twoOf ⊤\n${HOLDERS.pair.parts(use)}`));
}

// The callee hands a list that it made to the function, which answers its parameter: the answer and the
// list are one cell. `id` answers its parameter, `take` a new list (control).
const SUPPLY = {
  once: { sig: (a) => `(List Int → ${a}) → ${a} × List Int`, body: "x = [ 3, 1 ]\n( g x, x )" },
  twice: { sig: (a) => `(List Int → ${a}) → ${a} × ${a}`, body: "x = [ 3, 1 ]\n( g x, g x )" },
};
for (const [sn, S] of Object.entries(SUPPLY)) for (const [fn, fv] of Object.entries({ id: "λl → l", take: "λl → List.take l 9" })) for (const callee of ["generic", "local"]) for (const [un, use] of Object.entries(ANSWER_USES)) {
  const tw = un === "dead" ? "dead" : un === "back" ? "back.live" : "live";
  const lines = [];
  const decls = [];
  if (callee === "local") lines.push(`twoOf g =\n${ind(S.body, 4)}`);
  else decls.push(`twoOf : ${S.sig("a")}\ntwoOf g =\n${ind(S.body, 4)}`);
  lines.push(`r = twoOf (${fv})`, HOLDERS.pair.parts(use));
  add(`supply.${sn}.${fn}.${callee}.${fn === "take" && tw !== "dead" ? tw.replace("live", "none") : tw}`, program(decls, lines.join("\n")));
}

// ---- handon ----------------------------------------------------------------------------------------------
const H_ACTS = {
  keep: 'λl → Ref.set cell l',
  keepUpd: 'λl → Ref.update cell λ_ → l',
  read: 'λl → Ref.set cell [ List.length l ]',   // control: reads, keeps a new list
  write: 'λl → Ref.set cell (List.push l 5)',     // writes what it is handed
};
const H_CALLEES = {
  ret: 'both : (⊤ → a), (a → ⊤) → a\nboth g h =\n    x = g ⊤\n    h x\n    x',
  own: 'both : (⊤ → List Int), (List Int → ⊤) → List Int\nboth g h =\n    x = [ 3, 1 ]\n    h x\n    x',
  pair: 'both : (⊤ → a), (a → ⊤) → a × Int\nboth g h =\n    x = g ⊤\n    h x\n    ( x, 1 )',
};
for (const [an, act] of Object.entries(H_ACTS)) for (const [cn, callee] of Object.entries(H_CALLEES)) for (const twin of ['live', 'dead']) {
  const get = cn === 'pair' ? '.0' : '';
  const body = `cell = Ref.make [ 0 ]\ny = both (λ_ → [ n, 1 ]) (${act})${get ? '' : ''}\nw = List.set y${get} 0 9\n` +
    (twin === 'live' ? '"${ints w} ${ints (Ref.get cell)}"' : '"${ints w}"');
  add(`handon.${an}.${cn}.${an === 'read' && twin === 'live' ? 'none' : twin}`, program([callee], body));
}

// ---- compare ---------------------------------------------------------------------------------------------
const OPS = {
  eq: { m: 'eq', e: 'Bag q == Bag [ 1 ]' }, neq: { m: 'eq', e: 'Bag q ≠ Bag [ 1 ]' }, doteq: { m: 'eq', e: '(Bag q).eq (Bag [ 1 ])' },
  lt: { m: 'compare', e: 'Bag q < Bag [ 1 ]' }, le: { m: 'compare', e: 'Bag q ≤ Bag [ 1 ]' }, gt: { m: 'compare', e: 'Bag q > Bag [ 1 ]' },
  ge: { m: 'compare', e: 'Bag q ≥ Bag [ 1 ]' }, listeq: { m: 'eq', e: '[ Bag q ] == [ Bag [ 1 ] ]' }, dotcmp: { m: 'compare', e: '(Bag q).compare (Bag [ 1 ]) == EQ' },
};
const C_ACTS = {
  write: (xs) => `List.length (List.set ${xs} 0 9)`,
  keep: (xs) => `Ref.set cell ${xs}\nList.length ${xs}`,
  read: (xs) => `List.length ${xs}`,
};
for (const [on, op] of Object.entries(OPS)) for (const [an, act] of Object.entries(C_ACTS)) for (const vis of ['pub', 'priv', 'annot']) for (const twin of ['live', 'dead']) {
  const res = op.m === 'eq' ? `${act('xs')} == List.length ys` : `Basics.compare (${act('xs').split('\n').pop()}) (List.length ys)`;
  const pre = act('xs').split('\n').slice(0, -1);
  const inner = [...(op.m === 'eq' ? act('xs').split('\n').slice(0, -1) : pre), op.m === 'eq' ? `${act('xs').split('\n').pop()} == List.length ys` : res];
  const bodyM = `case a of\n    Bag xs →\n        case b of\n            Bag ys →\n${ind(inner.join('\n'), 16)}`;
  const ret = op.m === 'eq' ? 'Bool' : 'Order';
  const head = vis === 'annot' ? `pub ${op.m} : Bag, Bag → ${ret}\n${op.m} a b =` : `${vis === 'pub' ? 'pub ' : ''}${op.m} a b =`;
  const decls = ['type Bag = Bag (List Int)', 'cell : Ref (List Int)\ncell =\n    Ref.make [ 0 ]', `${head}\n${ind(bodyM, 4)}`];
  const tail = an === 'keep'
    ? (twin === 'live' ? 'w = List.set q 0 9\n"${t} ${ints w} ${ints (Ref.get cell)}"' : 'w = List.set q 0 9\n"${t} ${ints w}"')
    : (twin === 'live' ? '"${t} ${ints q}"' : '"${t}"');
  add(`compare.${on}.${an}.${vis}.${an === 'read' && twin === 'live' ? 'none' : twin}`, program(decls, `q = [ n, 1 ]\nt = if ${op.e} then "y" else "n"\n${tail}`));
}

// ---- sortwith --------------------------------------------------------------------------------------------
const S_ACTS = {
  keepA: 'Ref.set r a',
  keepB: 'Ref.set r b',
  keepUpd: 'Ref.update r λ_ → a',
  read: 'Ref.set r [ List.length a ]',
};
for (const [an, act] of Object.entries(S_ACTS)) for (const twin of ['live', 'dead']) {
  const body = `r = Ref.make [ 0 ]\nxss = [ [ n, 1, 1 ], [ n, 2 ] ]\ns = List.sortWith xss λa b →\n    ${act}\n    compare (List.length a) (List.length b)\n` +
    'k = String.fromInt (List.length s)\nw = List.update xss 0 λm → List.set m 0 9\nw2 = List.update w 1 λm → List.set m 0 9\n' +
    (twin === 'live' ? '"${k} ${ints (Ref.get r)} ${String.fromInt (List.length w2)}"' : '"${k} ${String.fromInt (List.length w2)}"');
  add(`sortwith.${an}.${an === 'read' && twin === 'live' ? 'none' : twin}`, program([], body));
}

// ---- dict ------------------------------------------------------------------------------------------------
const AT = 'at : Dict Int (List Int), Int → String\nat d k =\n    case Dict.get d k of\n        Just l →\n            ints l\n\n        Nothing →\n            "-"';
const D_MAKE = {
  two: { d: 'Dict.insert (Dict.insert Dict.empty 1 q) 2 q', read: 'at ed 2' },
  local: { d: 'Dict.insert Dict.empty 1 q', read: 'ints q' },
  from: { d: 'Dict.fromList [ ( 1, q ), ( 2, q ) ]', read: 'at ed 2' },
  union: { d: 'Dict.union (Dict.insert Dict.empty 1 q) (Dict.insert Dict.empty 2 q)', read: 'at ed 2' },
  apart: { d: 'Dict.insert (Dict.insert Dict.empty 1 q) 2 [ 5 ]', read: 'at ed 2' },
};
for (const [dn, D] of Object.entries(D_MAKE)) for (const twin of ['live', 'dead']) {
  const body = `q = [ n, 1 ]\nd = ${D.d}\ned = Dict.update d 1 λm → Maybe.map m λl → List.set l 0 9\n` +
    (twin === 'live' ? `"\${at ed 1} \${${D.read}}"` : '"${at ed 1}"');
  add(`dict.${dn}.${twin}`, program([AT], body));
}

// ---- front -----------------------------------------------------------------------------------------------
const F_ITEMS = {
  empty: { T: 'List (List Int)', xs: '[ [], [ n ], [ 2 ] ]', item: '[]', v: '[ 9 ]', show: 'ints' },
  tuple: { T: 'List (Int × Int)', xs: '[ ( 1, 2 ), ( n, 3 ), ( 4, 4 ) ]', item: '( 1, 2 )', v: '( 9, 9 )', show: 'λp → String.fromInt p.0' },
  same: { T: 'List (List Int)', xs: '[ [ 1 ], [ n ], [ 2 ] ]', item: 'y', v: '[ 9 ]', show: 'ints' },
};
for (const [fn, F] of Object.entries(F_ITEMS)) for (const twin of ['live', 'dead']) {
  const body = `xss = ${F.xs}\ncase xss of\n    [ y, …rest ] →\n        ys = [ ${F.item}, …rest ]\n        w = List.set ys 1 ${F.v}\n` +
    `        ${twin === 'live' ? '"${shows w} ${shows xss}"' : '"${shows w}"'}\n\n    _ →\n        "-"`;
  add(`front.${fn}.${fn !== 'same' && twin === 'live' ? 'none' : twin}`, program([`shows : ${F.T} → String\nshows ls =\n    String.join (List.map ls ${F.show}) ";"`], body));
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const [name, src] of programs) {
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), src);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
