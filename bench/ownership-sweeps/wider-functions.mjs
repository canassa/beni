// wider-functions.mjs <outdir> [filter]: a generator for a function value whose type and its holder's type are
// two readings of one type, where one is wider than the other. A function over a type variable (`a → a`,
// `List a → List a`) goes to a function parameter of a concrete type with nested lists, or of a type variable.
// Its answer holds the argument's deeper lists. The program then writes a deeper list of the answer, and
// (`live`) reads the same list through the argument. A hand search for research report 112 §6.3 found this
// corner: the prototype matched the function's type to the holder's in one direction, and the deeper lists of
// the answer had no holder. Programs are `<holder>.<fn>.<origin>.<shape>.<edit>.<mode>/Main.beni`.
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/wider-functions.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;

// Shapes: the concrete type `T` of the value. `mk`: a value of it around the list `inner`. `edits`: each is an
// expression that writes the list `inner` through `r` and prints the result (`upd`: with `List.update`, which
// reads the lists on the way in the same operation; `pat`: the list is taken out with a pattern first).
// `list`: the shape is a list at the top.
const SH = {
  lol: { T: 'List (List Int)', mk: '[ inner ]', list: true, edits: {
    upd: (r) => `shows (List.update ${r} 0 λm → List.push m 9)`,
    pat: (r) => `case ${r} of\n    [ m, …_ ] →\n        show (List.push m 9)\n\n    _ →\n        "-"` } },
  lll: { T: 'List (List (List Int))', mk: '[ [ inner ] ]', list: true, edits: {
    upd: (r) => `String.join (List.map (List.update ${r} 0 λmm → List.update mm 0 λm → List.push m 9) shows) "/"`,
    pat: (r) => `case ${r} of\n    [ [ m, …_ ], …_ ] →\n        show (List.push m 9)\n\n    _ →\n        "-"` } },
  pair: { T: 'List Int × List Int', mk: '( inner, [ 4 ] )', edits: { upd: (r) => `show (List.push ${r}.0 9)` } },
  rec: { T: '{ l : List Int, m : List Int }', mk: '{ l = inner, m = [ 4 ] }', edits: { upd: (r) => `show (List.push ${r}.l 9)` } },
  may: { T: 'Maybe (List Int)', mk: 'Just inner', edits: { pat: (r) => `case ${r} of\n    Just l →\n        show (List.push l 9)\n\n    Nothing →\n        "-"` } },
};

// Functions: each is over a type variable, and each answers its argument or a list with its elements.
// `listOnly`: its parameter is a list. `fold`: it has the two parameters of a fold's callback.
const FNS = {
  same: { sig: 'a → a', params: 'v', body: 'v', lam: 'λu → u' },
  sameL: { sig: 'List a → List a', params: 'xs', body: 'xs', lam: 'λys → List.take ys 99', listOnly: true },
  copyL: { sig: 'List a → List a', params: 'xs', body: 'List.map xs λel → el', lam: 'λys → List.map ys λel → el', listOnly: true },
  keepAcc: { sig: 'x, a → a', params: '_ v', body: 'v', lam: 'λ_ u → u', fold: true },
};

// Holders: a function with a function parameter of the concrete type (`run*`), or of a type variable (`app*`:
// then the holder's type is the wider one, and a function over `List a` has a variable one level down).
const HOLDERS = {
  run1: { sig: (T) => `(${T} → ${T}), ${T} → ${T}`, params: 'f v', body: 'f v' },
  runTwo: { sig: (T) => `(${T} → ${T}), ${T} → ${T}`, params: 'f v', body: 'f (f v)' },
  runFold: { sig: (T) => `(Int, ${T} → ${T}), ${T} → ${T}`, params: 'f v', body: 'List.foldl [ 1, 2 ] v f', fold: true },
  app: { sig: () => '(a → a), a → a', params: 'f v', body: 'f v' },
  appFold: { sig: () => '(Int, a → a), a → a', params: 'f v', body: 'List.foldl [ 1, 2 ] v f', fold: true },
};

function gen(holder, fname, origin, shape, edit, mode) {
  const H = HOLDERS[holder], F = FNS[fname], S = SH[shape];
  if (!S.edits[edit]) return null;
  if (!!H.fold !== !!F.fold) return null;
  if (F.listOnly && !S.list) return null;
  const PT = S.T.includes(' ') && !S.T.startsWith('{') ? `(${S.T})` : S.T;
  const decls = [fn('hold', H.sig(PT), H.params, H.body)];
  const lines = ['inner = [ n ]', `v = ${S.mk}`];
  let fexpr;
  if (origin === 'top') { decls.push(fn('wide', F.sig, F.params, F.body)); fexpr = 'wide'; }
  else if (origin === 'loc') { lines.push(`g = ${F.lam}`); fexpr = 'g'; }
  else fexpr = `(${F.lam})`;
  lines.push(`r = hold ${fexpr} v`);
  const e = S.edits[edit]('r');
  lines.push(e.includes('\n') ? `w =\n${ind(e, 4)}` : `w = ${e}`);
  lines.push(mode === 'live' ? 'w ++ "|" ++ show inner' : 'w');
  return [
    'import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n',
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('shows', 'List (List Int) → String', 'ls', 'String.join (List.map ls show) ";"'),
    ...decls,
    fn('go', 'Int → String', 'n', lines.join('\n')),
    'main : Program\nmain =\n    Node.print (go 0)\n',
  ].join('\n\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const holder of Object.keys(HOLDERS)) for (const fname of Object.keys(FNS)) for (const origin of ['top', 'loc', 'lam'])
  for (const shape of Object.keys(SH)) for (const edit of ['upd', 'pat']) for (const mode of ['live', 'dead']) {
    const name = `${holder}.${fname}.${origin}.${shape}.${edit}.${mode}`;
    if (filter && !name.includes(filter)) continue;
    const src = gen(holder, fname, origin, shape, edit, mode);
    if (!src) continue;
    const d = path.join(out, name);
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'Main.beni'), src);
    list.push(path.resolve(d));
  }
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
