// worded-bodies.mjs <outdir> [filter]: research report 162, a platform declaration with ownership words and
// a beni body that reaches no JavaScript. Its walk sees all of it, so a word that claims less than the walk
// found is refused at the platform's build (`false_ownership_word`, ownership-v3-kernel.md §6 rule 10, *A
// worded body is checked against its walk*). Before the report its contract was its words whatever the
// walk found, and a caller that trusted a false word wrote in place a value the body still read or kept.
//
// Each program `<row>.<words>.<twin>` has a test platform of its own (`_p/<program>`, written next to the
// programs) with one worded row, and a `Main` that calls it:
//
// - `<words>` is `lie` (the words say less than the body does: `shallow` on a body that reads a value,
//   `unused` on one that reads, `borrowed` on one that writes or keeps, `fresh` on one that answers a
//   parameter or a top-level value or a cell it let escape, `exclusive` on one new list at two places, a
//   function parameter `many` that the body keeps) or `honest` (the same body with true words, or a body
//   of which the same words are true). Every `lie` is REFUSED `false_ownership_word`; no `honest` one is.
// - `<twin>` is `live` (the program reads, after an in-place write that the false word would accept,
//   what the row read or kept: trusted, it traps or differs) or `dead` (it reads nothing of it after).
//   An honest `live` twin can be refused by the program's own write (`list_still_used`): that is the
//   word doing its work.
// - `<words>` is `unproven` for true words that the walk cannot show (`shallow` over a `List.foldl` whose
//   callback reads no element: the fold hands it each one): REFUSED `false_ownership_word`, the pessimistic side. It is `unjudged` for a
//   false count (`stored` once, stored twice), which the check does not judge: not refused, and its
//   `live` twin traps or differs, as a false `foreign` row's does.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/worded-bodies.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');

const header = `import Dict exposing (Dict)
import List
import Node exposing (Program)
import Ref exposing (Ref)
import Rows
import String


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","
`;

// Each row: its name, its declaration with `{W}` for the words (one entry of `words` per program), and a
// program for each twin. `lie` and `honest` are lists of [label, words, body?]: a body replaces `body`.
const rows = [
  {
    name: 'dictPeek',
    sig: (w) => `peek : ${w[0]} Dict Int (List Int) → Int`,
    body: 'peek d = List.length (Maybe.withDefault (Dict.get d 1) [])',
    lie: [['shallow', ['borrowed shallow']]],
    honest: [['borrowed', ['borrowed']], ['size', ['borrowed shallow'], 'peek d = Dict.size d'], ['member', ['borrowed shallow'], 'peek d = if Dict.member d 1 then 1 else 0']],
    live: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    n = Rows.peek d0
    [ ints ys, String.fromInt n ]`,
    dead: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    n = Rows.peek d0
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    name: 'listHead',
    sig: (w) => `firstLength : ${w[0]} List (List Int) → Int`,
    body: `firstLength l =
    case l of
        [ x, …_ ] →
            List.length x

        [] →
            0`,
    lie: [['shallow', ['borrowed shallow']]],
    honest: [['borrowed', ['borrowed']]],
    // True, and refused: `List.foldl` hands its callback each element, so the walk reads them. (A body of
    // `List.length l` is shown: `List.length` is `borrowed shallow`, #2584.)
    unproven: [['length', ['borrowed shallow'], 'firstLength l = List.foldl l 0 λ_ n → n + 1']],
    live: `    l0 = [ [ 1 ], [ 2 ] ]
    xs = Maybe.withDefault (List.head l0) []
    ys = List.push xs 5
    n = Rows.firstLength l0
    [ ints ys, String.fromInt n ]`,
    dead: `    l0 = [ [ 1 ], [ 2 ] ]
    n = Rows.firstLength l0
    xs = Maybe.withDefault (List.head l0) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    name: 'listFold',
    sig: (w) => `total : ${w[0]} List (List Int) → Int`,
    body: 'total l = List.foldl l 0 (λx acc → acc + List.length x)',
    lie: [['shallow', ['borrowed shallow']]],
    honest: [['borrowed', ['borrowed']]],
    live: `    l0 = [ [ 1 ], [ 2 ] ]
    xs = Maybe.withDefault (List.head l0) []
    ys = List.push xs 5
    n = Rows.total l0
    [ ints ys, String.fromInt n ]`,
    dead: `    l0 = [ [ 1 ], [ 2 ] ]
    n = Rows.total l0
    xs = Maybe.withDefault (List.head l0) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    name: 'dictFold',
    sig: (w) => `total : ${w[0]} Dict Int (List Int) → Int`,
    body: 'total d = Dict.foldl d 0 (λk v acc → acc + List.length v)',
    lie: [['shallow', ['borrowed shallow']]],
    honest: [['borrowed', ['borrowed']]],
    live: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    n = Rows.total d0
    [ ints ys, String.fromInt n ]`,
    dead: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    n = Rows.total d0
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    name: 'unused',
    sig: (w) => `count : ${w[0]} List Int → Int`,
    body: 'count l = List.length l',
    lie: [['unused', ['unused']]],
    honest: [['borrowed', ['borrowed']], ['constant', ['unused'], 'count l = 7']],
    live: `    xs = [ 1 ]
    ys = List.push xs 5
    n = Rows.count xs
    [ ints ys, String.fromInt n ]`,
    dead: `    xs = [ 1 ]
    n = Rows.count xs
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    name: 'writes',
    sig: (w) => `bump : ${w[0]} List Int → ${w[1]}List Int`,
    body: 'bump l = List.push l 5',
    lie: [['borrowed', ['borrowed', '']]],
    honest: [['written', ['written returned', '']]],
    live: `    xs = [ 1 ]
    ys = Rows.bump xs
    [ ints xs, ints ys ]`,
    dead: `    xs = [ 1 ]
    ys = Rows.bump xs
    [ ints ys ]`,
  },
  {
    name: 'dictWrites',
    sig: (w) => `bump : ${w[0]} Dict Int (List Int) → Dict Int (List Int)`,
    body: 'bump d = Dict.insert d 3 [ 3 ]',
    lie: [['borrowed', ['borrowed']]],
    honest: [['written', ['written returned']]],
    live: `    d0 = Dict.fromList [ ( 1, [ 1 ] ) ]
    d1 = Rows.bump d0
    [ String.fromInt (Dict.size d0), String.fromInt (Dict.size d1) ]`,
    dead: `    d0 = Dict.fromList [ ( 1, [ 1 ] ) ]
    d1 = Rows.bump d0
    [ String.fromInt (Dict.size d1) ]`,
  },
  {
    name: 'closure',
    sig: (w) => `later : ${w[0]} List Int → ${w[1]}(⊤ → Int)`,
    body: 'later l = λ⊤ → List.length l',
    lie: [['borrowed', ['borrowed', 'fresh ']], ['fresh', ['escaped', 'fresh ']]],
    honest: [['escaped', ['escaped', '']]],
    live: `    xs = [ 1 ]
    g = Rows.later xs
    ys = List.push xs 5
    [ ints ys, String.fromInt (g ⊤) ]`,
    dead: `    xs = [ 1 ]
    g = Rows.later xs
    n = g ⊤
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    name: 'cell',
    sig: (w) => `keep : ${w[0]} List Int → Ref (List Int)`,
    body: 'keep l = Ref.make l',
    lie: [['borrowed', ['borrowed']]],
    honest: [['escaped', ['escaped']]],
    live: `    xs = [ 1 ]
    r = Rows.keep xs
    ys = List.push xs 5
    [ ints ys, ints (Ref.get r) ]`,
    dead: `    xs = [ 1 ]
    ys = List.push xs 5
    r = Rows.keep ys
    [ ints (Ref.get r) ]`,
  },
  {
    name: 'answersParam',
    sig: (w) => `same : ${w[0]} List Int → ${w[1]}List Int`,
    body: 'same l = l',
    lie: [['fresh', ['borrowed', 'fresh ']]],
    honest: [['returned', ['returned', '']], ['copy', ['borrowed', 'fresh '], 'same l = List.copy l']],
    live: `    xs = [ 1 ]
    ys = Rows.same xs
    zs = List.push ys 5
    [ ints xs, ints zs ]`,
    dead: `    xs = [ 1 ]
    ys = Rows.same xs
    zs = List.push ys 5
    [ ints zs ]`,
  },
  {
    name: 'answersTop',
    sig: (w) => `start : borrowed Int → ${w[0]}List Int`,
    body: 'start n = if n > 0 then [ n ] else origin',
    extra: '\n\norigin : List Int\norigin = [ 1, 2 ]',
    lie: [['fresh', ['fresh ']]],
    honest: [['none', ['']], ['new', ['fresh '], 'start n = [ n ]']],
    live: `    ys = Rows.start 0
    zs = List.push ys 5
    [ ints zs, ints (Rows.start 0) ]`,
    dead: `    ys = Rows.start 0
    zs = List.push ys 5
    [ ints zs ]`,
  },
  {
    name: 'answersElement',
    sig: (w) => `first : borrowed List (List Int) → ${w[0]}List Int`,
    body: 'first l = Maybe.withDefault (List.head l) []',
    lie: [['fresh', ['fresh ']]],
    honest: [['elementof', ['elementof ']]],
    live: `    l0 = [ [ 1 ], [ 2 ] ]
    el = Rows.first l0
    el2 = List.push el 5
    [ ints el2, ints (Maybe.withDefault (List.head l0) []) ]`,
    dead: `    l0 = [ [ 1 ], [ 2 ] ]
    el = Rows.first l0
    el2 = List.push el 5
    [ ints el2 ]`,
  },
  {
    name: 'exclusive',
    sig: (w) => `pair : borrowed Int → ${w[0]} List Int × List Int`,
    body: `pair n =
    l = [ n ]
    ( l, l )`,
    lie: [['exclusive', ['fresh exclusive']]],
    honest: [['fresh', ['fresh']], ['two', ['fresh exclusive'], 'pair n = ( [ n ], [ n ] )']],
    live: `    ( a, b ) = Rows.pair 1
    a2 = List.push a 5
    [ ints a2, ints b ]`,
    dead: `    ( a, b ) = Rows.pair 1
    a2 = List.push a 5
    [ ints a2 ]`,
  },
  {
    name: 'escapedFresh',
    sig: (w) => `made : borrowed Int → ${w[0]}List Int × Ref (List Int)`,
    body: `made n =
    l = [ n ]
    ( l, Ref.make l )`,
    lie: [['fresh', ['fresh ']]],
    honest: [['none', ['']]],
    live: `    ( a, r ) = Rows.made 1
    a2 = List.push a 5
    [ ints a2, ints (Ref.get r) ]`,
    dead: `    ( a, r ) = Rows.made 1
    a2 = List.push a 5
    [ ints a2 ]`,
  },
  {
    name: 'keepsFunction',
    sig: (w) => `keep : ${w[0]} (⊤ → Int) → Ref (⊤ → Int)`,
    body: 'keep f = Ref.make f',
    lie: [['many', ['many']], ['once', ['once']]],
    honest: [['escaped', ['escaped']]],
    live: `    xs = [ 1 ]
    r = Rows.keep (λ⊤ → List.length xs)
    ys = List.push xs 5
    [ ints ys, String.fromInt ((Ref.get r) ⊤) ]`,
    dead: `    xs = [ 1 ]
    r = Rows.keep (λ⊤ → 7)
    ys = List.push xs 5
    [ ints ys, String.fromInt ((Ref.get r) ⊤) ]`,
  },
  {
    // A derived comparison of values that hold no cell reaches no JavaScript.
    name: 'derivedCompare',
    sig: (w) => `peek : ${w[0]} Dict Int (List Int) → Int`,
    body: `peek d =
    k = if ( 1, 2 ) == ( 2, 1 ) then 2 else 1
    List.length (Maybe.withDefault (Dict.get d k) [])`,
    lie: [['shallow', ['borrowed shallow']]],
    honest: [['borrowed', ['borrowed']]],
    live: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    n = Rows.peek d0
    [ ints ys, String.fromInt n ]`,
    dead: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    n = Rows.peek d0
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    // A walk that gives up has nothing to check the words against: refused.
    name: 'givesUp',
    sig: (w) => `peek : ${w[0]} Dict Int (List Int) → Int`,
    body: `peek d =
    xs = Maybe.withDefault (Dict.get d 1) []
    loop : Int, List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int → List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int × List Int
    loop n ( b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18, b19 ) = if n == 0 then ( b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18, b19 ) else loop (n - 1) ( b19, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18 )
    ( a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19 ) = loop 0 ( xs, [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [] )
    List.length a0`,
    lie: [['shallow', ['borrowed shallow']]],
    live: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    n = Rows.peek d0
    [ ints ys, String.fromInt n ]`,
    dead: `    d0 = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
    n = Rows.peek d0
    xs = Maybe.withDefault (Dict.get d0 1) []
    ys = List.push xs 5
    [ ints ys, String.fromInt n ]`,
  },
  {
    // A count of cells the body made alone is judged.
    name: 'freshTwice',
    sig: (w) => `mk : borrowed Int → ${w[0]} List (List Int)`,
    body: `mk n =
    t = [ n ]
    [ t, t ]`,
    lie: [['exclusive', ['fresh exclusive']]],
    honest: [['fresh', ['fresh']], ['two', ['fresh exclusive'], 'mk n = [ [ n ], [ n ] ]']],
    live: `    ys = Rows.mk 1
    case ys of
        [ a, b ] →
            a2 = List.push a 5
            [ ints a2, ints b ]

        _ →
            []`,
    dead: `    ys = Rows.mk 1
    case ys of
        [ a, _ ] →
            a2 = List.push a 5
            [ ints a2 ]

        _ →
            []`,
  },
  {
    // Not judged (a count): the words state one store, the body stores twice. A row of this kind is
    // trusted as a `foreign` one is, so its `live` twin is expected to trap or differ.
    name: 'twice',
    sig: (w) => `dupe : written returned List (List Int), ${w[0]} List Int → List (List Int)`,
    body: 'dupe l x = List.push (List.push l x) x',
    unjudged: [['stored', ['stored']]],
    live: `    ys = Rows.dupe [ [ 1 ] ] [ 2 ]
    case ys of
        [ _, a, b ] →
            a2 = List.push a 5
            [ ints a2, ints b ]

        _ →
            []`,
    dead: `    ys = Rows.dupe [ [ 1 ] ] [ 2 ]
    case ys of
        [ _, a, _ ] →
            a2 = List.push a 5
            [ ints a2 ]

        _ →
            []`,
  },
];

const progs = [];
for (const r of rows) {
  for (const [kind, list] of [['lie', r.lie ?? []], ['honest', r.honest ?? []], ['unproven', r.unproven ?? []], ['unjudged', r.unjudged ?? []]]) {
    for (const [label, words, body] of list) {
      for (const twin of ['live', 'dead']) {
        const name = `${r.name}.${kind}-${label}.${twin}`;
        if (filter && !name.includes(filter)) continue;
        const rowsBeni = `--! A sweep's platform: one worded row with a beni body that reaches no JavaScript (\`${kind}\`).

import Dict exposing (Dict)
import List
import Ref exposing (Ref)


pub ${r.sig(words)}
${body ?? r.body}${r.extra ?? ''}
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
  fs.writeFileSync(path.join(pd, 'beni.json'), `{ "platform": true, "name": "wordedbodies", "platforms": ["node"], "reexports": ["Node"] }\n`);
  fs.writeFileSync(path.join(pd, 'Rows.beni'), p.rowsBeni);
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  fs.writeFileSync(path.join(d, 'PLATFORM'), `${path.relative(root, path.resolve(pd))}\n`);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
