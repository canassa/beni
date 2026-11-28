// worded-no-location.mjs <outdir> [filter]: research report 150, a parameter that a contract puts in a
// result whose type, once filled in, has no location to hold it. The answer is the same JavaScript value,
// and a cast (`Js.to (Js.from v)`) reads it back as the list; so the list must escape where it went in,
// as a walked cast's does (`narrowed`, ownership-v3-kernel.md §3.4). Before the report the cells went
// nowhere, and a push of the list in place changed what the cast read back. Three families:
//
// - `row.<row>.<carrier>`: a test platform (`wordedrow`, written next to the programs) has a `foreign` row
//   for each word that puts a parameter in the result (`returned`, `stored`, `aliased`, `elementof`,
//   `taken`, a function parameter's answer under `once returned`), each at a result of no location (`Int`,
//   `Maybe Int`, `⊤`, `String`, `Int × Int`, a phantom type), and rows of a type variable read at one
//   (`returned a → b` at `Int`, `returned a → Maybe b` at `Maybe Int`). The row is called directly,
//   through a generic helper, through a helper in a second module, through a lambda, or handed to
//   `List.map` as a function value.
// - `copy.<carrier>`: a shallow copy at `Int` (`copyof Int`): the copy's elements are the list's, and the
//   program writes an inner list in place through `List.update`.
// - `inst.<shape>`: no row at all: a walked function whose result is a type variable, read by its caller
//   at a type of no location (`a, Int → b` at `Int`, `a → List Int × b` at a pair, `Maybe.map` and
//   `List.map` of a cast whose answers the caller reads at `Int`, a function `a → b` handed to a holder of
//   `a → Int`), and a cast of `( x, x )` read as `List Int × Int` (in a function `a → b`, through a holder of
//   `a → List Int × Int`, and by a row whose JavaScript answers `{a: a, b: a}`).
//
// Each program then pushes the list and reads the value read back (`live`) or not (`dead`).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/worded-no-location.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const progs = [];
const add = (name, files) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files });
};

const platformDir = path.join(path.resolve(out), '_wordedrow');
const platformRel = path.relative(root, platformDir);

// name, words, result type, JavaScript
const rows = [
  ['retInt', 'returned a → Int', 'Int', '(a) => a'],
  ['retMaybe', 'returned a → Maybe Int', 'Maybe Int', '(a) => a'],
  ['retUnit', 'returned a → ⊤', '⊤', '(a) => a'],
  ['retString', 'returned a → String', 'String', '(a) => a'],
  ['retPair', 'returned a → Int × Int', 'Int × Int', '(a) => a'],
  ['retPhantom', 'returned a → Tok a', 'Tok (List Int)', '(a) => a'],
  ['storedInt', 'stored a → Int', 'Int', '(a) => a'],
  ['storedUnit', 'stored a → ⊤', '⊤', '(a) => a'],
  ['aliasedInt', 'aliased a → Int', 'Int', '(a) => a'],
  ['retVar', 'returned a → b', 'Int', '(a) => a'],
  ['retMaybeVar', 'returned a → Maybe b', 'Maybe Int', '(a) => a'],
  ['retTwo', 'returned a, borrowed Int → b', 'Int', '(a, i) => a'],
];

const platform = `--! A sweep's platform: rows whose words put a parameter in a result of no location.

import Js


pub type Tok a
    = Tok Int


pub conv : a → b
conv v =
    Js.to (Js.from v)

${rows.map(([n, w]) => `
pub foreign pure ${n} : ${w}
`).join('')}

pub foreign pure atI : borrowed List a, borrowed Int → elementof Int


pub foreign pure takeI : borrowed List a, borrowed Int → taken Int


pub foreign pure copyI : borrowed List a → copyof Int


pub foreign pure runI : once returned sync (⊤ → a) → Int


pub foreign pure dupPair : returned a → a × Int
`;
const platformJs = `${rows.map(([n, , , js]) => `export const ${n} = ${js};`).join('\n')}
export const atI = (xs, i) => xs[i];
export const takeI = (xs, i) => xs[i];
export const copyI = (xs) => xs.slice();
export const runI = (f) => f();
export const dupPair = (a) => ({ a: a, b: a });
`;

const header = (extra = '') => `import Node exposing (Program)
import Pun exposing (Tok)${extra}
`;
const tail = (made, live) => `    z : List Int
    z = Pun.conv h
    x = List.length (List.push x0 9)
    v = ${live ? 'List.length z' : '0'}
    "\${String.fromInt x} \${String.fromInt v}"


main : Program
main =
    Node.print (go 0)
`;
const call = (n) => (n === 'retTwo' ? `Pun.${n} q 1` : `Pun.${n} q`);
const ref = (n) => (n === 'retTwo' ? `(Pun.${n} _ 1)` : `Pun.${n}`);
// The result type a helper of `a` declares: the phantom row's keeps the variable.
const helperType = (rt) => (rt === 'Tok (List Int)' ? 'Tok a' : rt);

for (const [n, , rt] of rows) for (const live of [true, false]) {
  const tw = live ? 'live' : 'dead';
  const ann = `    h : ${rt}\n`;
  // direct
  add(`row.${n}.direct.${tw}`, { 'Main.beni': `${header()}

go : Int → String
go n =
    x0 = [ n ]
${ann}    h = ${call(n).replace('q', 'x0')}
${tail('', live)}` });
  // a generic helper
  add(`row.${n}.generic.${tw}`, { 'Main.beni': `${header()}

via : a → ${helperType(rt)}
via q =
    ${call(n)}


go : Int → String
go n =
    x0 = [ n ]
    h = via x0
${tail('', live)}` });
  // a helper in a second module
  add(`row.${n}.other.${tw}`, { 'Main.beni': `${header('\nimport Other')}

go : Int → String
go n =
    x0 = [ n ]
    h = Other.via x0
${tail('', live)}`, 'Other.beni': `import Pun exposing (Tok)


pub via : a → ${helperType(rt)}
via q =
    ${call(n)}
` });
  // a lambda
  add(`row.${n}.lambda.${tw}`, { 'Main.beni': `${header()}

go : Int → String
go n =
    x0 = [ n ]
    f = λq → ${call(n)}
${ann}    h = f x0
${tail('', live)}` });
  // a function value handed to `List.map`
  add(`row.${n}.map.${tw}`, { 'Main.beni': `${header()}

go : Int → String
go n =
    x0 = [ n ]
    hs : List (${rt})
    hs = List.map [ x0 ] ${ref(n)}
    zs : List (List Int)
    zs = Pun.conv hs
    x = List.length (List.push x0 9)
    v = ${live ? 'List.length (List.concat zs)' : '0'}
    "\${String.fromInt x} \${String.fromInt v}"


main : Program
main =
    Node.print (go 0)
` });
}

// Elements answered at `Int`, and a function parameter's answer.
for (const live of [true, false]) {
  const tw = live ? 'live' : 'dead';
  for (const [n, made] of [['atI', 'Pun.atI outer 0'], ['takeI', 'Pun.takeI outer 0']]) {
    add(`row.${n}.direct.${tw}`, { 'Main.beni': `${header()}

go : Int → String
go n =
    x0 = [ n ]
    outer = [ x0 ]
    h = ${made}
${tail('', live)}` });
    add(`row.${n}.generic.${tw}`, { 'Main.beni': `${header()}

via : List a → Int
via outer =
    ${made}


go : Int → String
go n =
    x0 = [ n ]
    h = via [ x0 ]
${tail('', live)}` });
  }
  add(`row.runI.direct.${tw}`, { 'Main.beni': `${header()}

go : Int → String
go n =
    x0 = [ n ]
    h = Pun.runI λ⊤ → x0
${tail('', live)}` });
  add(`row.runI.generic.${tw}`, { 'Main.beni': `${header()}

via : a → Int
via q =
    Pun.runI λ⊤ → q


go : Int → String
go n =
    x0 = [ n ]
    h = via x0
${tail('', live)}` });
  for (const [carrier, made] of [['direct', 'Pun.copyI x0'], ['lambda', '(λq → Pun.copyI q) x0']]) {
    add(`copy.${carrier}.${tw}`, { 'Main.beni': `${header()}

go : Int → String
go n =
    x0 = [ [ n ], [ 2 ] ]
    h = ${made}
    zz : List (List Int)
    zz = Pun.conv h
    y = List.update x0 0 λq → List.push q 9
    x = List.sum (List.map y List.length)
    v = ${live ? 'List.sum (List.map zz List.length)' : '0'}
    "\${String.fromInt x} \${String.fromInt v}"


main : Program
main =
    Node.print (go 0)
` });
  }
}

// No row: walked functions whose result is read at an instance of no location.
const inst = {
  twoArgs: [`g : a, Int → b
g q _ =
    Pun.conv q
`, '    h : Int\n    h = g x0 1\n'],
  pair: [`g : a → List Int × b
g q =
    ( [ 1 ], Pun.conv q )
`, '    p : List Int × Int\n    p = g x0\n    ( _, h ) = p\n'],
  holder: [`apply : (a → Int), a → Int
apply f q =
    f q


cast : a → b
cast q =
    Pun.conv q
`, '    h = apply cast x0\n'],
  holderRow: [`apply : (a → Int), a → Int
apply f q =
    f q
`, '    h = apply Pun.retVar x0\n'],
  maybeMap: [`cast : a → b
cast q =
    Pun.conv q
`, '    m : Maybe Int\n    m = Maybe.map (Just x0) cast\n    h = Maybe.withDefault m 0\n'],
  pairCast: [`g : a → b
g q =
    Pun.conv ( q, q )
`, '    p : List Int × Int\n    p = g x0\n    ( _, h ) = p\n'],
  pairHolder: [`g : a → b
g q =
    Pun.conv ( q, q )


apply : (a → List Int × Int), a → List Int × Int
apply f q =
    f q
`, '    p = apply g x0\n    ( _, h ) = p\n'],
  pairRow: ['', '    p = Pun.dupPair x0\n    ( _, h ) = p\n'],
  maybeRow: ['', '    m : Maybe Int\n    m = Pun.retMaybeVar x0\n    h = Maybe.withDefault m 0\n'],
};
for (const [shape, [decls, body]] of Object.entries(inst)) for (const live of [true, false]) {
  add(`inst.${shape}.${live ? 'live' : 'dead'}`, { 'Main.beni': `${header()}
${decls ? `\n${decls}\n` : ''}
go : Int → String
go n =
    x0 = [ n ]
${body}${tail('', live)}` });
}
for (const live of [true, false]) add(`inst.listMap.${live ? 'live' : 'dead'}`, { 'Main.beni': `${header()}

cast : a → b
cast q =
    Pun.conv q


go : Int → String
go n =
    x0 = [ n ]
    hs : List Int
    hs = List.map [ x0 ] cast
    zs : List (List Int)
    zs = Pun.conv hs
    x = List.length (List.push x0 9)
    v = ${live ? 'List.length (List.concat zs)' : '0'}
    "\${String.fromInt x} \${String.fromInt v}"


main : Program
main =
    Node.print (go 0)
` });

// ---- write the programs ------------------------------------------------------------------------------------

fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "wordedrow", "platforms": ["node"], "reexports": ["Node"] }\n');
fs.writeFileSync(path.join(platformDir, 'Pun.beni'), platform);
fs.writeFileSync(path.join(platformDir, 'Pun.js'), platformJs);
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(p.files)) fs.writeFileSync(path.join(d, f), text);
  fs.writeFileSync(path.join(d, 'PLATFORM'), `${platformRel}\n`);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
