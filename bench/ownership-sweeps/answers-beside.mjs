// answers-beside.mjs <outdir> [filter]: a generator for the answer of a function beside another part of a result.
// A callee answers a value with two parts: the answer of a function that it was handed, and its argument (or a
// second answer). The callee cannot know if the two parts are one cell: that depends on the function. The
// caller then puts both parts into one list and writes one element, or writes one part and reads the other.
// A hand search for research report 112 §6.3 found this corner: the prototype trusted the callee's "the parts
// of my result are apart". Four callees have no function: the argument has one list at two places, which is
// the first-order form of the same claim. Programs are `<callee>.<fn>.<use>/Main.beni`.
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/answers-beside.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;
const F = '(List Int → List Int)';

// Callees: `decls` are the top-level functions, `call(f)` the call with the function expression `f`, and
// `parts` binds the two parts `p0` and `p1` of the result `r` around the lines `k` (a case when it must be one).
const P2 = 'List Int × List Int';
const bindPair = (k) => `p0 = r.0\np1 = r.1\n${k}`;
const bindList = (k) => `case r of\n    [ p0, p1 ] →\n${ind(k, 8)}\n\n    _ →\n        "-"`;
const CALLEES = {
  // The answer and the argument.
  pairAns: { decls: [fn('make', `${F}, List Int → ${P2}`, 'f xs', '( f xs, xs )')], call: (f) => `make ${f} [ n ]`, parts: bindPair },
  // Two calls of one function with one argument.
  pairTwo: { decls: [fn('make', `${F}, List Int → ${P2}`, 'f xs', 'a = f xs\nb = f xs\n( a, b )')], call: (f) => `make ${f} [ n ]`, parts: bindPair },
  // Two functions with one argument.
  pairFG: { decls: [fn('make', `${F}, ${F}, List Int → ${P2}`, 'f g xs', '( f xs, g xs )')], call: (f) => `make ${f} ${f} [ n ]`, parts: bindPair },
  // A record.
  recAns: { decls: [fn('make', `${F}, List Int → { a : List Int, b : List Int }`, 'f xs', '{ a = f xs, b = xs }')], call: (f) => `make ${f} [ n ]`,
    parts: (k) => `p0 = r.a\np1 = r.b\n${k}` },
  // The elements of one list.
  listAns: { decls: [fn('make', `${F}, List Int → List (List Int)`, 'f xs', '[ f xs, xs ]')], call: (f) => `make ${f} [ n ]`,
    parts: (k) => `case r of\n    [ p0, p1 ] →\n${ind(k, 8)}\n\n    _ →\n        "-"` },
  // Through one more function.
  wrapAns: { decls: [fn('inner', `${F}, List Int → ${P2}`, 'f xs', '( f xs, xs )'), fn('make', `${F}, List Int → ${P2}`, 'f xs', 'inner f xs')],
    call: (f) => `make ${f} [ n ]`, parts: bindPair },
  // One part is one level down.
  nestAns: { decls: [fn('make', `${F}, List Int → (List Int × Int) × List Int`, 'f xs', '( ( f xs, 0 ), xs )')], call: (f) => `make ${f} [ n ]`,
    parts: (k) => `p0 = r.0.0\np1 = r.1\n${k}` },
  // A callee over a type variable.
  genAns: { decls: [fn('make', '(a → a), a → a × a', 'f x', '( f x, x )')], call: (f) => `make ${f} [ n ]`, parts: bindPair },
  // The handed function makes the two parts, one with a function that it captured.
  viaBuild: { decls: [fn('make', '(x → a), x → a', 'build x', 'build x')], call: (f) => `make (λy → ( y, ${f} y )) [ n ]`, parts: bindPair },
  // No function: the callee only rearranges its argument, and the argument has one list at two places.
  argPair: { nofn: true, pre: 'q0 = [ n ]', decls: [fn('make', `${P2} → ${P2}`, 'p', '( p.0, p.1 )')], call: () => 'make ( q0, q0 )', parts: bindPair },
  argSwap: { nofn: true, pre: 'q0 = [ n ]', decls: [fn('make', 'a × b → b × a', 'p', '( p.1, p.0 )')], call: () => 'make ( q0, q0 )', parts: bindPair },
  argTwo: { nofn: true, pre: 'q0 = [ n ]', decls: [fn('make', `List Int, List Int → ${P2}`, 'x y', '( x, y )')], call: () => 'make q0 q0', parts: bindPair },
  // One summary location: the elements of the result are two parts of one argument, two parts of one answer,
  // or the answers of two functions that are handed two arguments.
  argList: { nofn: true, pre: 'q0 = [ n ]', decls: [fn('make', `${P2} → List (List Int)`, 'p', '[ p.0, p.1 ]')], call: () => 'make ( q0, q0 )', parts: bindList },
  ansList: { decls: [fn('make', `(List Int → ${P2}), List Int → List (List Int)`, 'h x', 'r0 = h x\n[ r0.0, r0.1 ]')],
    call: (f) => `make (λy → ( y, ${f} y )) [ n ]`, parts: bindList },
  twoList: { pre: 'q0 = [ n ]', decls: [fn('make', `${F}, ${F}, List Int, List Int → List (List Int)`, 'f g x y', '[ f x, g y ]')],
    call: (f) => `make ${f} ${f} q0 q0`, parts: bindList },
  // One answer source: two calls of one function, which is handed one list as two arguments, as two parts of
  // one argument, or two lists that are apart (the safe form).
  oneList: { pre: 'q0 = [ n ]', decls: [fn('make', `${F}, List Int, List Int → List (List Int)`, 'f x y', '[ f x, f y ]')],
    call: (f) => `make ${f} q0 q0`, parts: bindList },
  partList: { pre: 'q0 = [ n ]', decls: [fn('make', `${F}, ${P2} → List (List Int)`, 'f p', '[ f p.0, f p.1 ]')],
    call: (f) => `make ${f} ( q0, q0 )`, parts: bindList },
  apartList: { decls: [fn('make', `${F}, List Int, List Int → List (List Int)`, 'f x y', '[ f x, f y ]')],
    call: (f) => `make ${f} [ n ] [ n + 1 ]`, parts: bindList },
};

// Functions: what the handed function answers. `pre`: a line before the call.
const FNS = {
  id: { f: '(λl → l)' },                                  // its parameter: the two parts are one list
  take: { f: '(λl → List.take l 99)' },                   // a new list: the two parts are apart
  cap: { pre: 'k = [ 7 ]', f: '(λ_ → k)' },                 // a captured list: two answers are one list
  loc: { pre: 'g = λl → l', f: 'g' },                      // a local, over a type variable
};

// Uses: what the caller does with the two parts `p0` and `p1`.
const USES = {
  list: 'v = [ p0, p1 ]\nw = List.update v 0 λm → List.push m 9\nshows w',
  write: 'a = List.push p0 9\nshow a ++ "|" ++ show p1',
  writeDead: 'a = List.push p0 9\nshow a',
  swap: 'a = List.push p1 9\nshow a ++ "|" ++ show p0',
};

function gen(callee, fname, use) {
  const C = CALLEES[callee], G = FNS[fname];
  if (C.nofn && fname !== 'id') return null;
  const lines = [...(C.pre ? [C.pre] : []), ...(G.pre && !C.nofn ? [G.pre] : []), `r = ${C.call(G.f)}`, C.parts(USES[use])];
  if (use === 'list' && C.parts === bindList) lines.splice(lines.length - 1, 1, 'w = List.update r 0 λm → List.push m 9', 'shows w');
  return [
    'import List\nimport Node exposing (Program)\nimport String\n',
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('shows', 'List (List Int) → String', 'ls', 'String.join (List.map ls show) ";"'),
    ...C.decls,
    fn('go', 'Int → String', 'n', lines.join('\n')),
    'main : Program\nmain =\n    Node.print (go 0)\n',
  ].join('\n\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const callee of Object.keys(CALLEES)) for (const fname of Object.keys(FNS)) for (const use of Object.keys(USES)) {
  const name = `${callee}.${fname}.${use}`;
  if (filter && !name.includes(filter)) continue;
  if (!gen(callee, fname, use)) continue;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), gen(callee, fname, use));
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
