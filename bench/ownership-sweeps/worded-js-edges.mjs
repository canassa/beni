// worded-js-edges.mjs <outdir> [filter]: research report 164, two holes of report 162's check of worded beni
// bodies (`false_ownership_word`, ownership-v3-kernel.md §6 rule 10, *A worded body is checked against its
// walk*). Before the report one call of a core function built on `Js` (`round`, `String.fromInt`, `Js.same`
// of two new lists, …) turned the check off for the whole body, though the JavaScript it reached saw no cell
// of a parameter; and an alias (`same = keep`) was never compared with the contract of the function it names.
//
// Each program `<row>.<guard>.<words>.<twin>` has a test platform of its own (`_p/<program>`, written next to
// the programs: `Rows` with one worded row, `Help` with functions of no words), and a `Main` that calls it:
//
// - `<row>` is a body (`peek`: reads the list at key 1 of a dictionary; `same`: answers its list) under a
//   guard `<guard>`, a condition that is true at run time and calls JavaScript that sees no cell of the
//   parameter (or none, `plain`); or an alias form (`alias*`) of a function of the platform.
// - `<words>` is `lie` (the words say less than the body does: `shallow` on a body that reads a value,
//   `fresh` on one that answers its parameter) or `honest` (a body of which the same words are true).
//   Every `lie` is REFUSED `false_ownership_word`; no `honest` one is. `unproven` is an alias of a function
//   at a type variable, whose contract is at other types than the words': REFUSED `false_ownership_word`,
//   with the fix in its text (write it with its parameters). `trusted` is an alias of a function whose own
//   body hands its parameter to JavaScript: not checked, as a `foreign` row is not; only its `dead` twin.
// - `<twin>` is `live` (after an in-place write that a false word would accept, the program reads what the
//   row read: trusted, it traps or differs) or `dead` (it reads nothing of it after). An honest `live` twin
//   can be refused by the program's own write (`list_still_used`): that is the word doing its work.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/worded-js-edges.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');

const header = `import Dict exposing (Dict)
import List
import Node exposing (Program)
import Ref
import Rows
import String


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","
`;

// A condition true at run time that calls JavaScript, none of whose operands holds a cell of a parameter.
const guards = [
  ['plain', 'True'],
  ['round', 'round 1.5 == 2'],
  ['toFloat', 'toFloat 3 > 2.5'],
  ['idiv', '7 // 2 == 3'],
  ['fromInt', 'String.fromInt 12 == "12"'],
  ['append', '"a" ++ "b" == "ab"'],
  ['length', 'String.length "ab" == 2'],
  ['toString', 'Debug.toString 1 == "1"'],
  ['sameNew', 'not (Js.same [ 1 ] [ 1 ])'],
  ['isNullFrom', 'not (Js.isNull (Js.from "x"))'],
  ['helper', 'newSame ⊤'],
  ['helperOther', 'Help.newSame ⊤'],
  ['helperList', 'Help.sameList [ 3 ]'],
  ['interp', 'String.length "n=\${String.fromInt 4}" == 3'],
];

const help = `--! A module of a sweep's platform: functions of no words.

import Dict exposing (Dict)
import Js


pub newSame : ⊤ → Bool
newSame ⊤ = not (Js.same [ 2 ] [ 2 ])


pub sameList : List Int → Bool
sameList l = not (Js.same l [ 4 ])


pub inner : Dict Int (List Int) → Int
inner d = List.length (Maybe.withDefault (Dict.get d 1) [])


pub size : Dict Int (List Int) → Int
size d = Dict.size d


pub viaJs : Dict Int (List Int) → Int
viaJs d = if Js.same [ d ] [ d ] then List.length (Maybe.withDefault (Dict.get d 1) []) else 0
`;

const dictLive = `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    n = Rows.peek d0
    [ ints ys, String.fromInt n ]`;
const dictDead = `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    n = Rows.peek d0
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`;
const listLive = `    xs = [ 1 ]
    ys = Rows.same xs
    zs = List.push ys 5
    [ ints xs, ints zs ]`;
const listDead = `    xs = [ 1 ]
    ys = Rows.same xs
    zs = List.push ys 5
    [ ints zs ]`;
const recLive = `    xs = [ 1 ]
    r = Rows.wrap xs
    zs = List.push r.items 5
    [ ints xs, ints zs ]`;
const recDead = `    xs = [ 1 ]
    r = Rows.wrap xs
    zs = List.push r.items 5
    [ ints zs ]`;

// Each row: its name, its words' signature, and per kind a list of [label, declarations].
const rows = [];
for (const [g, cond] of guards) {
  rows.push({
    name: `peek.${g}`,
    lie: [['shallow', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek d = if ${cond} then List.length (Maybe.withDefault (Dict.get d 1) []) else 0`]],
    honest: [['size', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek d = if ${cond} then Dict.size d else 0`]],
    live: dictLive,
    dead: dictDead,
  });
  rows.push({
    name: `same.${g}`,
    lie: [['fresh', `pub same : borrowed List Int → fresh List Int
same l = if ${cond} then l else []`]],
    honest: [['copy', `pub same : borrowed List Int → fresh List Int
same l = if ${cond} then List.copy l else []`]],
    live: listLive,
    dead: listDead,
  });
}
rows.push(
  {
    name: 'aliasSame',
    lie: [['fresh', `pub same : borrowed List Int → fresh List Int
same = keep


keep : List Int → List Int
keep l = l`]],
    honest: [['copy', `pub same : borrowed List Int → fresh List Int
same = keep


keep : List Int → List Int
keep l = List.copy l`]],
    unproven: [['typeVar', `pub same : returned List Int → List Int
same = keep


keep : a → a
keep x = x`]],
    live: listLive,
    dead: listDead,
  },
  {
    name: 'aliasOther',
    lie: [['shallow', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = Help.inner`]],
    honest: [['size', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = Help.size`]],
    unproven: [['core', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = Dict.size`]],
    trusted: [['viaJs', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = Help.viaJs`]],
    live: dictLive,
    dead: dictDead,
  },
  {
    name: 'aliasChain',
    lie: [['shallow', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = mid


mid : Dict Int (List Int) → Int
mid = Help.inner`]],
    honest: [['size', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = mid


mid : Dict Int (List Int) → Int
mid = Help.size`]],
    live: dictLive,
    dead: dictDead,
  },
  {
    // A function value with no parameter that is no name, no lambda and no partial: no walk at the
    // words' types, so refused whatever it does (`unproven` for the honest one).
    name: 'valueIf',
    lie: [['fresh', `pub same : borrowed List Int → fresh List Int
same = if True then keep else keep


keep : List Int → List Int
keep l = l`]],
    unproven: [['copy', `pub same : borrowed List Int → fresh List Int
same = if True then keep else keep


keep : List Int → List Int
keep l = List.copy l`]],
    live: listLive,
    dead: listDead,
  },
  {
    name: 'aliasLambda',
    lie: [['shallow', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = λd → if round 1.5 == 2 then Help.inner d else 0`]],
    honest: [['size', `pub peek : borrowed shallow Dict Int (List Int) → Int
peek = λd → if round 1.5 == 2 then Help.size d else 0`]],
    live: dictLive,
    dead: dictDead,
  },
  {
    // A new value at a type variable, from a row of the platform whose JavaScript makes one: a body of a
    // platform is judged in full there (research report 164's review).
    name: 'madeVar',
    lie: [['exclusive', `pub dupe : ⊤ → fresh exclusive List a
dupe ⊤ =
    x = Mk.make ⊤
    [ x, x ]`]],
    honest: [['fresh', `pub dupe : ⊤ → fresh List a
dupe ⊤ =
    x = Mk.make ⊤
    [ x, x ]`]],
    live: `    ys = Rows.dupe ⊤
    case ys of
        [ a, b ] →
            a2 = List.push a 5
            [ ints a2, ints b ]

        _ →
            []`,
    dead: `    ys = Rows.dupe ⊤
    case ys of
        [ a, _ ] →
            a2 = List.push a 5
            [ ints a2 ]

        _ →
            []`,
  },
  {
    name: 'madeGive',
    lie: [['once', `pub give : once (a → ⊤) → fresh a
give g =
    x = Mk.make ⊤
    g x
    x`]],
    live: `    r = Ref.make [ 0 ]
    ys = Rows.give λv → Ref.set r v
    zs = List.push ys 5
    [ ints zs, ints (Ref.get r) ]`,
    dead: `    r = Ref.make [ 0 ]
    ys = Rows.give λv → Ref.set r v
    zs = List.push ys 5
    [ ints zs ]`,
  },
  {
    name: 'aliasRecord',
    lie: [['fresh', `pub wrap : borrowed List Int → fresh { items : List Int }
wrap = mk


mk : List Int → { items : List Int }
mk l = { items = l }`]],
    honest: [['copy', `pub wrap : borrowed List Int → fresh { items : List Int }
wrap = mk


mk : List Int → { items : List Int }
mk l = { items = List.copy l }`]],
    live: recLive,
    dead: recDead,
  },
);

const progs = [];
for (const r of rows) {
  for (const [kind, list] of [['lie', r.lie ?? []], ['honest', r.honest ?? []], ['unproven', r.unproven ?? []], ['trusted', r.trusted ?? []]]) {
    for (const [label, decls] of list) {
      for (const twin of kind === 'trusted' ? ['dead'] : ['live', 'dead']) {
        const name = `${r.name}.${kind}-${label}.${twin}`;
        if (filter && !name.includes(filter)) continue;
        const rowsBeni = `--! A sweep's platform: one worded row with a beni body (\`${kind}\`).

import Dict exposing (Dict)
import Help
import Js
import List
import Mk


${decls}


newSame : ⊤ → Bool
newSame ⊤ = not (Js.same [ 2 ] [ 2 ])
`;
        const main = `${header}

go : ⊤ → List String
go ⊤ =
${r[twin]}


main : Program
main = Node.printLines (go ⊤)
`;
        progs.push({ name, rowsBeni, main });
      }
    }
  }
}

const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  const pd = path.join(out, '_p', p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.mkdirSync(pd, { recursive: true });
  fs.writeFileSync(path.join(pd, 'beni.json'), `{ "platform": true, "name": "wordedjsedges", "platforms": ["node"], "reexports": ["Node"] }\n`);
  fs.writeFileSync(path.join(pd, 'Rows.beni'), p.rowsBeni);
  fs.writeFileSync(path.join(pd, 'Help.beni'), help);
  fs.writeFileSync(path.join(pd, 'Mk.beni'), `--! A module of a sweep's platform: a row whose JavaScript answers a new list at any type.\n\n\npub foreign pure make : ⊤ → fresh a\n`);
  fs.writeFileSync(path.join(pd, 'Mk.js'), 'export const make = (u) => [1];\n');
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  fs.writeFileSync(path.join(d, 'PLATFORM'), `${path.relative(root, path.resolve(pd))}\n`);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
