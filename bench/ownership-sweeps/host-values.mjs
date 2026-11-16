// host-values.mjs <outdir> [filter]: research report 146, values that `Js` gives a type with more places
// than the value's own type has. A `Js.Value`, or a type variable, has one location; read as a list of
// records, as nested lists, as a `Maybe` or a tuple, every location below it holds what that one location
// holds (ownership-v3-kernel.md §3.4). Before the report, a reading through the call map found nothing
// there, and an element of the answer was a cell nobody else held. Six families:
//
// - `cast.*`: a test platform (`hostcast`, written next to the programs) answers its argument through
//   `Js.to (Js.from x)` at another type, directly, through a local the type check generalises, through
//   a `Js.array`, with one value twice, through `List.map` of `Js.to`, at nested lists, a `Maybe`, a
//   tuple and a record field. The program writes a part of the answer (a record update or a push), then
//   reads the argument (`live`) or not (`dead`).
// - `twice.*`: the platform answers one value twice in a list (`Js.array [ x, x ]`); the program writes
//   one element and reads the other (`live`) or the written one only (`dead`).
// - `queue.*`: `Queue.takeAll` and `Queue.takeN` hand back what was offered, a record or a list, at the
//   first element or nested in a pair, after `offer` or `offerAll`.
// - `describe.*`: a definition of `Schema.describe` written and read after.
// - `split.*`: the platform answers one value at two places of a type whose locations are single
//   (`Js.to (Js.from ( x, x ))` read as a pair or a record): the two parts are one value. The program
//   writes one part, directly or through a callee, and reads the other (`live`) or not (`dead`).
// - `own.*`: the answer is a new value the platform makes (`Js.array []`, a literal it converts): a
//   write of it, the argument read after; refused or the same.
//
// The last part of a name is the twin kind (bench/ownership-sweeps/README.md).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/host-values.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const progs = [];
const add = (name, main, platform) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, main, platform });
};

const platformDir = path.join(path.resolve(out), '_hostcast');
const platformRel = path.relative(root, platformDir);

const castModule = `--! A sweep's platform: values given another type through \`Js\`.

import Js
import List


pub asList : a → List b
asList x = Js.to (Js.from x)


pub viaLocal : a → List b
viaLocal x =
    got = Js.to (Js.from x)
    got


pub viaArray : a → List a
viaArray x = Js.to (Js.array [ Js.from x ])


pub twice : a → List a
twice x = Js.to (Js.array [ Js.from x, Js.from x ])


pub mapTo : List a → List b
mapTo xs = List.map xs λx → Js.to (Js.from x)


pub nested : a → List (List b)
nested x = Js.to (Js.from x)


pub maybeOf : a → Maybe b
maybeOf x = Js.to (Js.from x)


pub pairOf : a → b × Int
pairOf x = Js.to (Js.array [ Js.from x, Js.from 1 ])


pub boxed : a → { item : b }
boxed x = Js.to (Js.object [ ( "item", Js.from x ) ])


pub fresh : a → List b
fresh _ = Js.to (Js.array [])

pub twinT : a → b
twinT x = Js.to (Js.from ( x, x ))


pub twinA : a → b
twinA x = Js.to (Js.array [ Js.from x, Js.from x ])


pub twinR : a → b
twinR x = Js.to (Js.object [ ( "a", Js.from x ), ( "b", Js.from x ) ])


pub cast : a → b
cast x = Js.to (Js.from x)
`;

const header = (extra) => `import HostCast
import List
import Node exposing (Program)${extra}


type alias R =
    x : Int
    y : Int
`;

const recordProg = (pattern, made, read, total) => `${header('')}

go : Int → String
go n =
    r0 = { x = n, y = 2 }
    w =
        case ${made} of
            ${pattern} →
                { v | x = 99 }${total ? '' : `

            _ →
                r0`}
    "\${String.fromInt w.x} \${String.fromInt ${read}}"


main : Program
main = Node.print (go 1)
`;

const listProg = (pattern, made, read, total) => `${header('')}

go : Int → String
go n =
    xs = [ n, 2 ]
    w =
        case ${made} of
            ${pattern} →
                List.push v 9${total ? '' : `

            _ →
                xs`}
    "\${String.fromInt (List.length w)} \${String.fromInt ${read}}"


main : Program
main = Node.print (go 1)
`;

// [name, made from r0 (record) or xs (list), pattern binding `v`, whether the pattern matches every value]
const shapes = [
  ['asList', 'HostCast.asList [ X ]', '[ v, …_ ]'],
  ['viaLocal', 'HostCast.viaLocal [ X ]', '[ v, …_ ]'],
  ['viaArray', 'HostCast.viaArray X', '[ v, …_ ]'],
  ['mapTo', 'HostCast.mapTo [ X ]', '[ v, …_ ]'],
  ['nested', 'HostCast.nested [ [ X ] ]', '[ [ v, …_ ], …_ ]'],
  ['maybe', 'HostCast.maybeOf X', 'Just v'],
  ['pair', 'HostCast.pairOf X', '( v, _ )', true],
  ['boxed', '(HostCast.boxed X).item', 'v', true],
  ['nestedLast', 'HostCast.nested [ [ X ] ]', '[ …_, [ …_, v ] ]'],
];
for (const [name, made, pattern, total] of shapes) {
  add(`cast.${name}.record.live`, recordProg(pattern, made.replace('X', 'r0'), 'r0.x', total), platformRel);
  add(`cast.${name}.record.dead`, recordProg(pattern, made.replace('X', 'r0'), 'r0.y', total), platformRel);
  add(`cast.${name}.list.live`, listProg(pattern, made.replace('X', 'xs'), '(List.length xs)', total), platformRel);
  add(`cast.${name}.list.dead`, listProg(pattern, made.replace('X', 'xs'), '0', total), platformRel);
}

// ---- twice: one value at two places of the answer -------------------------------------------------------

const twiceRecord = (read) => `${header('')}

go : Int → String
go n =
    r0 = { x = n, y = 2 }
    case HostCast.twice r0 of
        [ a, b ] →
            w = { a | x = 99 }
            "\${String.fromInt w.x} \${String.fromInt ${read}}"

        _ →
            "none"


main : Program
main = Node.print (go 1)
`;
add('twice.record.live', twiceRecord('b.x'), platformRel);
add('twice.record.dead', twiceRecord('b.y'), platformRel);
const twiceList = (read) => `${header('')}

go : Int → String
go n =
    case HostCast.twice [ n, 2 ] of
        [ a, b ] →
            w = List.push a 9
            "\${String.fromInt (List.length w)} \${String.fromInt ${read}}"

        _ →
            "none"


main : Program
main = Node.print (go 1)
`;
add('twice.list.live', twiceList('(List.length b)'), platformRel);
add('twice.list.dead', twiceList('0'), platformRel);

// ---- split: one value at two single places ---------------------------------------------------------------

const splitProg = (made, ty, pat, write, read, helper) => `${header('')}

type alias Two =
    a : List Int
    b : List Int
${helper}

go : Int → String
go n =
    xs = [ n, 2 ]
    p : ${ty}
    p = ${made}
    case p of
        ${pat} →
            w = ${write}
            "\${String.fromInt (List.length w)} \${String.fromInt ${read}}"


main : Program
main = Node.print (go 1)
`;
const bump = `

bump : List Int × List Int → List Int
bump q =
    case q of
        ( a, _ ) →
            List.push a 9
`;
for (const [fn, made] of [['twinT', 'HostCast.twinT xs'], ['twinA', 'HostCast.twinA xs'], ['castPair', 'HostCast.cast ( xs, xs )']]) {
  add(`split.${fn}.pair.live`, splitProg(made, 'List Int × List Int', '( a, b )', 'List.push a 9', '(List.length b)', ''), platformRel);
  add(`split.${fn}.pair.dead`, splitProg(made, 'List Int × List Int', '( a, b )', 'List.push a 9', '0', ''), platformRel);
  add(`split.${fn}.callee.live`, splitProg(made, 'List Int × List Int', '( _, b )', 'bump p', '(List.length b)', bump), platformRel);
  add(`split.${fn}.callee.dead`, splitProg(made, 'List Int × List Int', '( _, b )', 'bump p', '0', bump), platformRel);
}
add('split.twinR.record.live', splitProg('HostCast.twinR xs', 'Two', '{ a, b }', 'List.push a 9', '(List.length b)', ''), platformRel);
add('split.twinR.record.dead', splitProg('HostCast.twinR xs', 'Two', '{ a, b }', 'List.push a 9', '0', ''), platformRel);
add('split.twinT.record.live', splitProg('HostCast.twinT xs', 'Two', '{ a, b }', 'List.push a 9', '(List.length b)', ''), platformRel);

const directProg = (made, read) => `${header('')}

bump : List Int × List Int → Int × Int
bump q =
    case q of
        ( a, b ) →
            w = List.push a 9
            ( List.length w, ${read} )


go : Int → String
go n =
    ( x, y ) = bump (${made})
    "\${String.fromInt x} \${String.fromInt y}"


main : Program
main = Node.print (go 1)
`;
for (const [fn, made] of [['twinT', 'HostCast.twinT [ n, 2 ]'], ['twinA', 'HostCast.twinA [ n, 2 ]'], ['twinR', 'HostCast.twinR [ n, 2 ]']]) {
  add(`split.${fn}.direct.live`, directProg(made, 'List.length b'), platformRel);
  add(`split.${fn}.direct.dead`, directProg(made, '0'), platformRel);
}

// ---- own: a new value the platform makes ------------------------------------------------------------------

const ownProg = (read) => `${header('')}

go : Int → String
go n =
    xs = [ n, 2 ]
    w = List.push (HostCast.fresh xs) 9
    "\${String.fromInt (List.length w)} \${String.fromInt ${read}}"


main : Program
main = Node.print (go 1)
`;
add('own.fresh.live', ownProg('(List.length xs)'), platformRel);
add('own.fresh.dead', ownProg('0'), platformRel);

// ---- queue: what `Queue.take*` hands back -----------------------------------------------------------------

const queueProg = (kind, take, offer, pattern, read) => `import Io
import List
import Node exposing (Program)
import Queue


type alias R =
    x : Int
    y : Int


go : Int → Program
go n =
    r0 = { x = n, y = 2 }
    xs = [ n, 2 ]
    q = Queue.unbounded ⊤
    _ = ${offer}
    w =
        case ${take} of
            ${pattern} →
                ${kind === 'record' ? '{ v | x = 99 }' : 'List.push v 9'}

            _ →
                ${kind === 'record' ? 'r0' : 'xs'}
    Node.print "\${String.fromInt ${kind === 'record' ? 'w.x' : '(List.length w)'}} \${String.fromInt ${read}}"


main : Program
main = Io.run λ⊤ → go 1
`;
const queueCases = [
  ['takeAll', 'Queue.takeAll q', 'offer', '[ v, …_ ]'],
  ['takeN', 'Queue.takeN q 1', 'offer', '[ v, …_ ]'],
  ['takeAllMany', 'Queue.takeAll q', 'offerAll', '[ v, …_ ]'],
  ['takeAllPair', 'Queue.takeAll q', 'pair', '[ ( v, _ ), …_ ]'],
];
for (const [name, take, how, pattern] of queueCases) {
  for (const kind of ['record', 'list']) {
    const x = kind === 'record' ? 'r0' : 'xs';
    const offer = how === 'offer' ? `Queue.offer q ${x}` : how === 'offerAll' ? `Queue.offerAll q [ ${x}, ${x} ]` : `Queue.offer q ( ${x}, 1 )`;
    const live = kind === 'record' ? 'r0.x' : '(List.length xs)';
    const dead = kind === 'record' ? 'r0.y' : '0';
    add(`queue.${name}.${kind}.live`, queueProg(kind, take, offer, pattern, live), null);
    add(`queue.${name}.${kind}.dead`, queueProg(kind, take, offer, pattern, dead), null);
  }
}

// ---- describe: a definition of a description --------------------------------------------------------------

const describeProg = (read) => `import Node
import Schema exposing (Codec)


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)


codecOf : List a → Codec a
    where a.codec : ⊤ → Codec a
codecOf _ = a.codec ⊤


trees : List (Tree Int)
trees = []


main : Node.Program
main =
    d = Schema.describe (codecOf trees)
    case d.definitions of
        [ def, …_ ] →
            w = { def | name = "changed" }
            Node.print "\${w.name} \${${read}}"

        [] →
            Node.print "none"
`;
add('describe.name.live', describeProg('def.name'), null);
add('describe.name.dead', describeProg('String.fromInt def.id'), null);

// ---- write the programs ------------------------------------------------------------------------------------

fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "hostcast", "platforms": ["node"], "reexports": ["Node"] }\n');
fs.writeFileSync(path.join(platformDir, 'HostCast.beni'), castModule);
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  if (p.platform) fs.writeFileSync(path.join(d, 'PLATFORM'), `${p.platform}\n`);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
