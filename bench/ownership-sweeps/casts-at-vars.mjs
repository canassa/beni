// casts-at-vars.mjs <outdir> [filter]: research report 151, a function of a type variable (`a → b`) whose
// JavaScript puts its argument one level down in its answer, at a part that the caller's reading of `b`
// has no location for: an `Int` element of a `List Int`, the `Int` part of a pair, the `Int` field of a
// record. The caller then casts that part back (`Js.to (Js.from v)`) and reads the list, which a push in
// place changed. Each leaker hides the list `x0`, and the program pushes `x0` and reads the cast-back value
// (`live`) or not (`dead`). The leakers live on a test platform (`castvar`, written next to the programs):
//
// - worded rows whose type variables differ (`returned a → b`, `aliased a → b`, `stored a → List b`), whose
//   JavaScript answers `[a]`, `{a: a, b: []}` or `{p: [], q: a}`, read at a type of the same layout as the
//   argument's: before the report the place graph had one place for every type variable, so the row was no
//   cast and its call an identity (the blind round T's F1 and F3);
// - walked code that builds a `Js.Value` of parts (`Js.array [ Js.from x ]`, `Js.object`) and reads it at a
//   type variable, or reads back a `Js.Value` a row nested (the blind round's F2);
// - a `Js.Value` inside a container read at a type variable (`fromMaybeV (Just (wrapV ( x, x )))`, `List
//   Js.Value → b`), and a cast of a type variable to another inside a `Maybe` (#2544).
//
// Each leaker is called directly, through a generic helper `via : a → b`, through a helper in a second module,
// through a lambda, through a lambda whose answer is a type variable, handed to `List.map`, `Maybe.map`, and
// to a generic `apply`.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/casts-at-vars.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const progs = [];
const add = (name, files) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files });
};

const platformDir = path.join(path.resolve(out), '_castvar');
const platformRel = path.relative(root, platformDir);

const platform = `--! A sweep's platform: functions of a type variable that put their argument below their answer.

import Dict exposing (Dict)
import Js


pub conv : a → b
conv v =
    Js.to (Js.from v)


pub foreign pure wrap : returned a → b


pub foreign pure wrapPair : returned a → b


pub foreign pure swapIn : returned a → b


pub foreign pure aliasedL : aliased a → b


pub foreign pure storedL : stored a → List b


pub foreign pure nestV : returned a → Js.Value


pub viaNest : a → b
viaNest x =
    Js.to (nestV x)


pub box : a → b
box x =
    Js.to (Js.array [ Js.from x ])


pub boxR : a → b
boxR x =
    Js.to (Js.object [ ( "q", Js.from x ), ( "p", Js.array [] ) ])


pub boxV : a → Js.Value
boxV x =
    Js.array [ Js.from x ]


pub boxVTo : a → b
boxVTo x =
    Js.to (boxV x)


pub wrapV : a → Js.Value
wrapV x =
    Js.from x


pub fromMaybeV : Maybe Js.Value → b
fromMaybeV m =
    case m of
        Just v →
            Js.to v

        Nothing →
            Js.to (Js.from 0)


pub fromListV : List Js.Value → b
fromListV l =
    case l of
        [ v, …_ ] →
            Js.to v

        _ →
            Js.to (Js.from 0)


pub fm : Maybe a → b
fm m =
    case m of
        Just v →
            Js.to (Js.from v)

        Nothing →
            Js.to (Js.from 0)


pub pairOfMaybeV : a → b
pairOfMaybeV x =
    fromMaybeV (Just (wrapV ( x, x )))


pub pairOfListV : a → b
pairOfListV x =
    fromListV [ wrapV ( x, x ) ]


pub pairOfFm : a → b
pairOfFm x =
    fm (Just ( x, x ))


pub type Tree a
    = Leaf
    | Node a (Tree a)


pub deepCast : Tree a → b
deepCast t =
    case t of
        Node _ (Node v _) →
            Js.to (Js.from v)

        _ →
            Js.to (Js.from 0)


pub dictCast : Dict String a → b
dictCast d =
    case Dict.get d "k" of
        Just v →
            Js.to (Js.from v)

        Nothing →
            Js.to (Js.from 0)


pub fromTreeV : Tree Js.Value → b
fromTreeV t =
    case t of
        Node _ (Node v _) →
            Js.to v

        _ →
            Js.to (Js.from 0)


pub fromDictV : Dict String Js.Value → b
fromDictV d =
    case Dict.get d "k" of
        Just v →
            Js.to v

        Nothing →
            Js.to (Js.from 0)
`;
const platformJs = `export const wrap = (a) => [a];
export const wrapPair = (a) => ({ a: a, b: [] });
export const swapIn = (a) => ({ p: [], q: a });
export const aliasedL = (a) => [a];
export const storedL = (a) => [[a]];
export const nestV = (a) => [a];
`;

// name, the reading of the answer, how the program reads the hidden part back as a list.
const atList = ['List Int', '    z : List Int\n    z = Pun.conv (Maybe.withDefault (List.head h) 0)\n'];
const atPair = ['Int × List Int', '    ( hq, _ ) = h\n    z : List Int\n    z = Pun.conv hq\n'];
const atPair2 = ['List Int × Int', '    ( _, hq ) = h\n    z : List Int\n    z = Pun.conv hq\n'];
const atRecord = ['{ p : List Int, q : Int }', '    z : List Int\n    z = Pun.conv h.q\n'];
const atNested = ['List (List Int)', '    z : List Int\n    z = Pun.conv (Maybe.withDefault (Maybe.andThen (List.head h) List.head) 0)\n'];
const leakers = [
  ['wrap', atList],
  ['wrapPair', atPair],
  ['swapIn', atRecord],
  ['aliasedL', atList],
  ['storedL', atNested],
  ['viaNest', atList],
  ['box', atList],
  ['boxR', atRecord],
  ['boxVTo', atList],
  ['pairOfMaybeV', atPair2],
  ['pairOfListV', atPair2],
  ['pairOfFm', atPair2],
];

const header = (extra = '') => `import Node exposing (Program)
import Pun${extra}
`;
const tail = (live) => `    x = List.length (List.push x0 9)
    v = ${live ? 'List.length z' : '0'}
    "\${String.fromInt x} \${String.fromInt v}"


main : Program
main =
    Node.print (go 1)
`;

for (const [n, [rt, back]] of leakers) for (const live of [true, false]) {
  const tw = live ? 'live' : 'dead';
  const ann = `    h : ${rt}\n`;
  const prog = (carrier, decls, body, extraFiles = {}, imports = '') => add(`${n}.${carrier}.${tw}`, {
    'Main.beni': `${header(imports)}
${decls ? `\n${decls}\n` : ''}
go : Int → String
go n =
    x0 = [ n ]
${body}${back}${tail(live)}`,
    ...extraFiles,
  });
  prog('direct', '', `${ann}    h = Pun.${n} x0\n`);
  prog('generic', `via : a → ${n === 'storedL' ? 'List b' : 'b'}
via q =
    Pun.${n} q
`, `${ann}    h = via x0\n`);
  prog('other', '', `${ann}    h = Other.via x0\n`, { 'Other.beni': `import Pun


pub via : a → ${n === 'storedL' ? 'List b' : 'b'}
via q =
    Pun.${n} q
` }, '\nimport Other');
  prog('lambda', '', `    f = λq → Pun.${n} q\n${ann}    h = f x0\n`);
  prog('thunk', '', `    k = λ⊤ → Pun.${n} x0\n${ann}    h = k ⊤\n`);
  prog('listMap', '', `    hs : List (${rt})\n    hs = List.map [ x0 ] Pun.${n}\n    h = Maybe.withDefault (List.head hs) (Pun.conv 0)\n`);
  prog('maybeMap', '', `    hm : Maybe (${rt})\n    hm = Maybe.map (Just x0) Pun.${n}\n    h = Maybe.withDefault hm (Pun.conv 0)\n`);
  prog('apply', `apply : (a → b), a → b
apply f q =
    f q
`, `${ann}    h = apply Pun.${n} x0\n`);
}

// A record written in place after it was hidden at an \`Int\` field (the blind round's \`WordedVarSameRecord\`).
for (const n of ['swapIn', 'boxR']) for (const live of [true, false]) {
  add(`${n}.recordWrite.${live ? 'live' : 'dead'}`, { 'Main.beni': `${header()}

type alias R =
    p : List Int
    q : Int


go : Int → String
go n =
    r0 = { p = [ n ], q = n }
    h : R
    h = Pun.${n} r0
    back : R
    back = Pun.conv h.q
    s = { r0 | q = 50 }
    v = ${live ? 'back.q' : '0'}
    "\${String.fromInt s.q} \${String.fromInt v}"


main : Program
main =
    Node.print (go 1)
` });
}


// #2544: a `Js.Value` inside a container cast at a type variable, written in the program itself (the
// review of research report 150's `lambdaMaybeV`), and a cast of one type variable to another reached
// through a path that no step of the place graph names (a cycle's deep level, a `Dict`), through an
// argument of the caller's own type variable, and through a function value.
const residuals = {
  maybeVInline: ['', '    h : List Int × Int\n    h = Pun.fromMaybeV (Just (Pun.wrapV ( x0, x0 )))\n'],
  maybeVThunk: ['', '    k = λ⊤ → Pun.fromMaybeV (Just (Pun.wrapV ( x0, x0 )))\n    h : List Int × Int\n    h = k ⊤\n'],
  listVThunk: ['', '    k = λ⊤ → Pun.fromListV [ Pun.wrapV ( x0, x0 ) ]\n    h : List Int × Int\n    h = k ⊤\n'],
  fmInline: ['', '    h : List Int × Int\n    h = Pun.fm (Just ( x0, x0 ))\n'],
  fmThunk: ['', '    k = λ⊤ → Pun.fm (Just ( x0, x0 ))\n    h : List Int × Int\n    h = k ⊤\n'],
  deepLevel: ['', '    h : List Int × Int\n    h = Pun.deepCast (Pun.Node ( [], [] ) (Pun.Node ( x0, x0 ) Pun.Leaf))\n'],
  dictInside: ['', '    h : List Int × Int\n    h = Pun.dictCast (Dict.singleton "k" ( x0, x0 ))\n'],
  callerVar: [`h2 : a → b
h2 y =
    Pun.fm (Just y)
`, '    h : List Int × Int\n    h = h2 ( x0, x0 )\n'],
  fnValue: [`apply : (a → b), a → b
apply f q =
    f q
`, '    h : List Int × Int\n    h = apply Pun.fm (Just ( x0, x0 ))\n'],
  fnValueMap: ['', '    hs : List (List Int × Int)\n    hs = List.map [ Just ( x0, x0 ) ] Pun.fm\n    h = Maybe.withDefault (List.head hs) ( [], 0 )\n'],
  treeV: ['', '    h : List Int × Int\n    h = Pun.fromTreeV (Pun.Node (Pun.wrapV 0) (Pun.Node (Pun.wrapV ( x0, x0 )) Pun.Leaf))\n'],
  dictV: ['', '    h : List Int × Int\n    h = Pun.fromDictV (Dict.singleton "k" (Pun.wrapV ( x0, x0 )))\n'],
  treeVThunk: ['', '    k = λ⊤ → Pun.fromTreeV (Pun.Node (Pun.wrapV 0) (Pun.Node (Pun.wrapV ( x0, x0 )) Pun.Leaf))\n    h : List Int × Int\n    h = k ⊤\n'],
};
for (const [shape, [decls, body]] of Object.entries(residuals)) for (const live of [true, false]) {
  add(`residual.${shape}.${live ? 'live' : 'dead'}`, { 'Main.beni': `${header('\nimport Dict')}
${decls ? `\n${decls}\n` : ''}
go : Int → String
go n =
    x0 = [ n ]
${body}${atPair2[1]}${tail(live)}` });
}

// ---- write the programs ------------------------------------------------------------------------------------

fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "castvar", "platforms": ["node"], "reexports": ["Node"] }\n');
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
