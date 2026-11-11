// aliased-arguments.mjs <outdir> [filter]: a generator for one list at two places of what a call takes.
// A callee makes a result with two parts from two inputs. The caller hands it one list as both inputs: as two
// arguments, as two items of a tuple, a record or a list, through a local, or through a projection. A function
// that the callee was handed can stand between an input and a part, and that function can answer its
// parameter, a new list, or a list that it captured. The caller then writes one part in place and reads the
// other, or reads nothing (the safe twin).
//
// The callee's contract says that its two parts are two cells. That claim rests on the arguments and on the
// functions, which only the caller knows (research report 112 §2.7). A hand search found this corner (§6.3).
// This generator was written after the fixes of that search and run one time (§6.4).
// Programs are `<alias>.<callee>.<fn>.<use>/Main.beni`. See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/aliased-arguments.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const L = 'List Int';
const F = `(${L} → ${L})`;

// Alias forms: how the callee gets its two inputs `x` and `y`, and what the caller hands it. `pre`: lines before
// the call. `sig`, `params`: the callee's parameters after its functions. `x`, `y`: the two inputs in the body.
// `wrap`: the body must take the inputs out of a list first. Each form but `apart` hands the list `q` two times.
const ALIAS = {
  two: { sig: `${L}, ${L}`, params: 'x y', x: 'x', y: 'y', args: 'q q' },
  apart: { sig: `${L}, ${L}`, params: 'x y', x: 'x', y: 'y', args: 'q [ n + 1 ]' },
  pair: { sig: `${L} × ${L}`, params: 'p', x: 'p.0', y: 'p.1', args: '( q, q )' },
  rec: { sig: `{ a : ${L}, b : ${L} }`, params: 'p', x: 'p.a', y: 'p.b', args: '{ a = q, b = q }' },
  list: { sig: `List (${L})`, params: 'xs', x: 'x', y: 'y', wrap: '[ x, y, …_ ]', args: '[ q, q ]' },
  localPair: { pre: 't = ( q, q )', sig: `${L} × ${L}`, params: 'p', x: 'p.0', y: 'p.1', args: 't' },
  localList: { pre: 'u = [ q, q ]', sig: `List (${L})`, params: 'xs', x: 'x', y: 'y', wrap: '[ x, y, …_ ]', args: 'u' },
  proj: { pre: 't = ( ( q, q ), 5 )', sig: `${L} × ${L}`, params: 'p', x: 'p.0', y: 'p.1', args: 't.0' },
  listAndOne: { sig: `List (${L}), ${L}`, params: 'xs y', x: 'x', y: 'y', wrap: '[ x, …_ ]', args: '[ q ] q' },
};

// Callees: the result's type, how it is made from the two parts `X` and `Y`, a value for the case with no
// inputs, and how the caller binds the two parts `p0` and `p1` of the result `r` around the lines `k`.
const bindPair = (k) => `p0 = r.0\np1 = r.1\n${k}`;
const bindList = (k) => `case r of\n    [ p0, p1 ] →\n${ind(k, 8)}\n\n    _ →\n        "-"`;
const CALLEES = {
  mkPair: { T: `${L} × ${L}`, mk: (X, Y) => `( ${X}, ${Y} )`, none: '( [], [] )', parts: bindPair },
  mkSwap: { T: `${L} × ${L}`, mk: (X, Y) => `( ${Y}, ${X} )`, none: '( [], [] )', parts: bindPair },
  mkRec: { T: `{ a : ${L}, b : ${L} }`, mk: (X, Y) => `{ a = ${X}, b = ${Y} }`, none: '{ a = [], b = [] }', parts: (k) => `p0 = r.a\np1 = r.b\n${k}` },
  mkMaybe: { T: `Maybe (${L}) × ${L}`, mk: (X, Y) => `( Just (${X}), ${Y} )`, none: '( Nothing, [] )',
    parts: (k) => `case r.0 of\n    Just p0 →\n        p1 = r.1\n${ind(k, 8)}\n\n    Nothing →\n        "-"` },
  mkList: { T: `List (${L})`, list: true, mk: (X, Y) => `[ ${X}, ${Y} ]`, none: '[]', parts: bindList },
  mkAppend: { T: `List (${L})`, list: true, mk: (X, Y) => `List.append [ ${X} ] [ ${Y} ]`, none: '[]', parts: bindList },
  mkSpread: { T: `List (${L})`, list: true, mk: (X, Y) => `[ ${X}, …[ ${Y} ] ]`, none: '[]', parts: bindList },
  mkNest: { T: `List (List (${L}))`, mk: (X, Y) => `[ [ ${X} ], [ ${Y} ] ]`, none: '[]',
    parts: (k) => `case r of\n    [ [ p0, …_ ], [ p1, …_ ] ] →\n${ind(k, 8)}\n\n    _ →\n        "-"` },
};

// Function settings: which inputs go through a handed function (`on`), how many functions the callee takes
// (`fns`), and what the function answers (`kind`).
const KINDS = {
  id: '(λl → l)',                 // its parameter
  take: '(λl → List.take l 99)',  // a new list
  cap: '(λ_ → q)',                 // a list that it captured: the list that is an argument too
};
const FNS = { none: { fns: 0 } };
for (const kind of Object.keys(KINDS)) {
  FNS[`fx-${kind}`] = { fns: 1, kind, X: (x) => `f ${x}`, Y: (y) => y };
  FNS[`fboth-${kind}`] = { fns: 1, kind, X: (x) => `f ${x}`, Y: (y) => `f ${y}` };
}
FNS['fy-cap'] = { fns: 1, kind: 'cap', X: (x) => x, Y: (y) => `f ${y}` };
for (const kind of ['id', 'cap']) FNS[`fg-${kind}`] = { fns: 2, kind, X: (x) => `f ${x}`, Y: (y) => `g ${y}` };

// Uses: what the caller does with the two parts. `direct` writes an element of the result itself.
const USES = {
  upd: 'v = [ p0, p1 ]\nw = List.update v 0 λm → List.push m 9\nshows w',
  pat: 'w = List.push p0 9\nshow w ++ "|" ++ show p1',
  second: 'w = List.push p1 9\nshow w ++ "|" ++ show p0',
  arg: 'w = List.push p0 9\nshow w ++ "|" ++ show q',
  dead: 'w = List.push p0 9\nshow w',
  direct: 'w = List.update r 0 λm → List.push m 9\nshows w',
};

function gen(alias, callee, fname, use) {
  const A = ALIAS[alias], C = CALLEES[callee], G = FNS[fname];
  if (use === 'direct' && !C.list) return null;
  const X = G.fns ? G.X(A.x) : A.x, Y = G.fns ? G.Y(A.y) : A.y;
  let body = C.mk(X, Y);
  if (A.wrap) body = `case xs of\n    ${A.wrap} →\n${ind(body, 8)}\n\n    _ →\n        ${C.none}`;
  const fsig = G.fns ? `${Array(G.fns).fill(F).join(', ')}, ` : '';
  const fparams = ['', 'f ', 'f g '][G.fns];
  const fargs = G.fns ? `${Array(G.fns).fill(KINDS[G.kind]).join(' ')} ` : '';
  const lines = ['q = [ n ]', ...(A.pre ? [A.pre] : []), `r = make ${fargs}${A.args}`, use === 'direct' ? USES.direct : C.parts(USES[use])];
  return [
    'import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n',
    `show : ${L} → String\nshow l =\n    String.join (List.map l String.fromInt) ","\n`,
    `shows : List (${L}) → String\nshows ls =\n    String.join (List.map ls show) ";"\n`,
    `make : ${fsig}${A.sig} → ${C.T}\nmake ${fparams}${A.params} =\n${ind(body, 4)}\n`,
    `go : Int → String\ngo n =\n${ind(lines.join('\n'), 4)}\n`,
    'main : Program\nmain =\n    Node.print (go 0)\n',
  ].join('\n\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const alias of Object.keys(ALIAS)) for (const callee of Object.keys(CALLEES)) for (const fname of Object.keys(FNS)) for (const use of Object.keys(USES)) {
  const name = `${alias}.${callee}.${fname}.${use}`;
  if (filter && !name.includes(filter)) continue;
  const src = gen(alias, callee, fname, use);
  if (!src) continue;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), src);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
