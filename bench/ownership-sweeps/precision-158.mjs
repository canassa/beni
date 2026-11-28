// precision-158.mjs <outdir> [filter]: the acceptances of research report 158 crossed with live twins.
//
// `tree.<shape>.<twin>`: a tree of records, written in place by a recursive writer (`bumpAll`) and at
// its root after it (`rootKids`, a constructor pattern whose parts are apart, `ownership-v3-kernel.md`
// §4.4). `<shape>` is how the tree is made: `lit` of distinct records, `param` handed by a caller,
// `left` and `right` built by a recursive insert, and the trees that hold one record twice: `both`
// (both children), `rootkid` (the root and a child), `deep` (two levels down). `<twin>` is `dead` (the
// old tree is not read after) or `live` (it is).
//
// `join.<fn>.<twin>`: a function answers its tree at the root in one arm and below new nodes in the
// other (`wrapN`, `accR`, `sw`), or at two places of one arm (`accA`, `pairT`), and a recursive writer
// writes each list of the answer (§4.4, *One value of a join at a time*).
//
// `dict.<src>.<twin>`: a list taken out of a dictionary and pushed (§3.1, §3.4): `empty` (`Dict.empty`),
// `single` (`Dict.singleton` of a parameter key), `top` (a top-level dictionary), `fromlist` (built
// at the top level), `shared` (two keys of one list).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/precision-158.mjs <outdir> [filter]'); process.exit(2); }
const progs = [];
const add = (name, main) => { if (name.includes(filter)) progs.push({ name, main }); };
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const TREE = `import List
import Node exposing (Program)
import String


type Tree a
    = Node (Tree a) a (Tree a)
    | Leaf


type alias R =
    n : Int
    xs : List Int


mk : Int → R
mk k = { n = k, xs = [ k ] }


bumpAll : Tree R → Tree R
bumpAll t =
    case t of
        Node l v r →
            Node (bumpAll l) { v | n = v.n + 1, xs = List.push v.xs v.n } (bumpAll r)

        Leaf →
            Leaf


rootKids : Tree R → Tree R
rootKids t =
    case bumpAll t of
        Node l v r →
            Node l { v | xs = List.push v.xs 0 } r

        Leaf →
            Leaf


insL : Tree a, a → Tree a
insL t x =
    case t of
        Node l v r →
            Node (insL l x) v r

        Leaf →
            Node Leaf x Leaf


insR : Tree a, a → Tree a
insR t x =
    case t of
        Node l v r →
            Node l v (insR r x)

        Leaf →
            Node Leaf x Leaf


show : Tree R → String
show t =
    case t of
        Node l v r →
            sep = ","
            "(\${show l} \${String.fromInt v.n}:\${String.join (List.map v.xs String.fromInt) sep} \${show r})"

        Leaf →
            "."


viaParam : Tree R → String
viaParam t = show (rootKids t)
`;

const SHAPES = {
  lit: 'Node (Node Leaf (mk 1) Leaf) (mk 2) (Node Leaf (mk 3) Leaf)',
  param: null,
  left: 'insL (insL (insL Leaf (mk 1)) (mk 2)) (mk 3)',
  right: 'insR (insR (insR Leaf (mk 1)) (mk 2)) (mk 3)',
  both: 'Node (Node Leaf r0 Leaf) (mk 2) (Node Leaf r0 Leaf)',
  rootkid: 'Node (Node Leaf r0 Leaf) r0 Leaf',
  deep: 'Node (Node (Node Leaf r0 Leaf) (mk 2) Leaf) (mk 3) (Node Leaf r0 Leaf)',
};
for (const [k, expr] of Object.entries(SHAPES)) {
  for (const twin of ['dead', 'live']) {
    const tree = expr ?? 'Node (Node Leaf (mk 1) Leaf) (mk 2) (Node Leaf (mk 3) Leaf)';
    const call = expr === null ? 'viaParam t' : 'show (rootKids t)';
    const tail = twin === 'live' ? `"\${${call}} \${show t}"` : call;
    add(`tree.${k}.${twin}`, `${TREE}

main : Program
main =
    r0 = mk 9
    t = ${tree}
    Node.print (${tail})
`);
  }
}

const JOIN = `import List
import Node exposing (Program)
import String


type Tree
    = Node Tree (List Int) Tree
    | Leaf


incAll : Tree → Tree
incAll t =
    case t of
        Node l xs r →
            Node (incAll l) (List.push xs 1) (incAll r)

        Leaf →
            Leaf


wrapN : Int, Tree → Tree
wrapN n a =
    if n == 0 then
        a
    else
        Node (wrapN (n - 1) a) [] Leaf


accR : Int, Tree → Tree
accR n a =
    if n == 0 then
        a
    else
        Node Leaf [] (accR (n - 1) a)


sw : Tree, Tree → Tree
sw a b =
    case a of
        Leaf →
            b

        Node al xs _ →
            Node (sw b al) xs Leaf


accA : Int, Tree → Tree
accA n a =
    if n == 0 then
        Node a [] a
    else
        Node (accA (n - 1) a) [] Leaf


pairT : Int, Tree → Tree
pairT n a =
    if n == 0 then
        a
    else
        Node (pairT (n - 1) a) [] a


show : Tree → String
show t =
    case t of
        Node l xs r →
            sep = ","
            "(\${show l} \${String.join (List.map xs String.fromInt) sep} \${show r})"

        Leaf →
            "."
`;
const JOINS = { wrapN: 'wrapN 2 t', accR: 'accR 2 t', sw: 'sw t (Node Leaf [ 5 ] Leaf)', accA: 'accA 1 t', pairT: 'pairT 1 t' };
for (const [k, call] of Object.entries(JOINS)) {
  for (const twin of ['dead', 'live']) {
    const tail = twin === 'live' ? `"\${show (incAll (${call}))} \${show t}"` : `show (incAll (${call}))`;
    add(`join.${k}.${twin}`, `${JOIN}

main : Program
main =
    t = Node Leaf [ 7 ] (Node Leaf [ 8 ] Leaf)
    Node.print (${tail})
`);
  }
}

const DICT = `import Dict exposing (Dict)
import List
import Node exposing (Program)
import String


seeded : Dict Int (List Int)
seeded = Dict.fromList [ ( 3, [ 7 ] ) ]


bumped : Dict Int (List Int), Int → List Int
bumped d k =
    case Dict.get d k of
        Just xs →
            List.push xs 1

        Nothing →
            []


single : Int, List Int → Dict Int (List Int)
single k l = Dict.singleton k l


show : List Int → String
show l = String.join (List.map l String.fromInt) ","
`;
const DICTS = {
  empty: ['Dict.empty', '3'],
  single: ['single 3 [ 4 ]', '3'],
  top: ['seeded', '3'],
  fromlist: ['Dict.fromList [ ( 3, [ 5 ] ) ]', '3'],
  shared: ['Dict.insert (single 3 l0) 4 l0', '3'],
};
for (const [k, [d, key]] of Object.entries(DICTS)) {
  for (const twin of ['dead', 'live']) {
    const tail = twin === 'live' ? `[ show (bumped d ${key}), show (Maybe.withDefault (Dict.get d ${key}) []), show l0 ]` : `[ show (bumped d ${key}) ]`;
    add(`dict.${k}.${twin}`, `${DICT}

main : Program
main =
    l0 = [ 1, 2 ]
    d = ${d}
    Node.printLines ${tail}
`);
  }
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const p of progs) {
  const d = path.resolve(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
