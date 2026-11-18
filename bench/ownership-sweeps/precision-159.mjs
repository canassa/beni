// precision-159.mjs <outdir> [filter]: the acceptances of research report 159 crossed with live twins.
//
// `getset.<src>.<twin>`: a record read out of a list with `List.get` and put back with `List.set`
// (`ownership-v3-kernel.md` §6 rule 10, *A position*), then a walk that writes every element's `coord`
// record and `tags` list in place (`mutate`). `<src>` is how `place` puts it back: `same` (a copy at the
// index it was read from), `fold` (`same`, folded over two indices), `back` (the record itself, at
// its index), `other` (a copy at another index: the `coord` record at two places), `otherlist` (read
// out of one board, put into another), `swap` (two reads, two writes), `expr` (the index computed
// again), `alias` (the index bound again to another local), `rest` (read out of a pattern's rest, put
// into the list), `dup` (the board's list holds one record twice). `<twin>` is `dead` (nothing but
// the new board is read after the walk) or `live` (the record read, which shares its `coord` with
// its copy, is read after the walk).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/precision-159.mjs <outdir> [filter]'); process.exit(2); }
const progs = [];
const add = (name, main) => { if (name.includes(filter)) progs.push({ name, main }); };
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const GETSET = `import List
import Node exposing (Program)
import String


type alias P =
    x : Int


type alias Cell =
    coord : P
    occ : Int
    tags : List Int


type alias Board =
    cells : List Cell


mutate : List Cell, List Cell → List Cell
mutate cs acc =
    case cs of
        [ c, …rest ] →
            p = c.coord
            mutate rest (List.push acc { c | coord = { p | x = p.x + 100 }, tags = List.push c.tags 9 })

        [] →
            acc


showCell : Cell → String
showCell c =
    "\${String.fromInt c.coord.x}/\${String.fromInt c.occ}/\${String.fromInt (List.length c.tags)}"


show : Board → String
show board =
    String.join (List.map board.cells showCell) ","


cell : Int → Cell
cell n =
    { coord = { x = n }, occ = 0, tags = [ n ] }


board0 : ⊤ → Board
board0 ⊤ =
    { cells = [ cell 1, cell 2, cell 3 ] }


none : Cell
none =
    cell 0
`;

const PLACES = {
  same: `place : Int, Board → Board × Cell
place i board =
    case List.get board.cells i of
        Just c →
            ( { board | cells = List.set board.cells i { Record.copy c | occ = 5 } }, c )

        Nothing →
            ( board, none )
`,
  fold: `placeOne : Int, Board → Board
placeOne i board =
    case List.get board.cells i of
        Just c →
            { board | cells = List.set board.cells i { Record.copy c | occ = i + 1 } }

        Nothing →
            board


place : Int, Board → Board × Cell
place i board =
    ( List.foldl [ i, 2 ] board λk b → placeOne k b, none )
`,
  back: `place : Int, Board → Board × Cell
place i board =
    case List.get board.cells i of
        Just c →
            ( { board | cells = List.set board.cells i c }, c )

        Nothing →
            ( board, none )
`,
  other: `place : Int, Board → Board × Cell
place i board =
    j = i + 1
    case List.get board.cells i of
        Just c →
            ( { board | cells = List.set board.cells j { Record.copy c | occ = 5 } }, c )

        Nothing →
            ( board, none )
`,
  otherlist: `place : Int, Board → Board × Cell
place i board =
    source = board0 ⊤
    case List.get source.cells i of
        Just c →
            ( { board | cells = List.set board.cells i { Record.copy c | occ = 5 } }, c )

        Nothing →
            ( board, none )
`,
  swap: `place : Int, Board → Board × Cell
place i board =
    j = i + 1
    case ( List.get board.cells i, List.get board.cells j ) of
        ( Just a, Just b ) →
            l1 = List.set board.cells i { Record.copy b | occ = 5 }
            ( { board | cells = List.set l1 j { Record.copy a | occ = 6 } }, a )

        _ →
            ( board, none )
`,
  expr: `place : Int, Board → Board × Cell
place i board =
    case List.get board.cells i of
        Just c →
            ( { board | cells = List.set board.cells (i + 0) { Record.copy c | occ = 5 } }, c )

        Nothing →
            ( board, none )
`,
  alias: `place : Int, Board → Board × Cell
place i board =
    k = i
    case List.get board.cells i of
        Just c →
            ( { board | cells = List.set board.cells k { Record.copy c | occ = 5 } }, c )

        Nothing →
            ( board, none )
`,
  rest: `place : Int, Board → Board × Cell
place i board =
    case board.cells of
        [ _, …rest ] →
            case List.get rest i of
                Just c →
                    ( { board | cells = List.set board.cells i { Record.copy c | occ = 5 } }, c )

                Nothing →
                    ( board, none )

        [] →
            ( board, none )
`,
  dup: `place : Int, Board → Board × Cell
place i board =
    shared = cell 7
    b = { board | cells = [ shared, shared, cell 8 ] }
    case List.get b.cells i of
        Just c →
            ( { b | cells = List.set b.cells i { Record.copy c | occ = 5 } }, c )

        Nothing →
            ( b, none )
`,
};

for (const [src, place] of Object.entries(PLACES)) {
  for (const twin of ['dead', 'live']) {
    const tail = twin === 'live' ? `"\${show b2} \${showCell old}"` : `show b2`;
    add(`getset.${src}.${twin}`, `${GETSET}

${place}

main : Program
main =
    ( b1, old ) = place 0 (board0 ⊤)
    b2 = { b1 | cells = mutate b1.cells [] }
    Node.print (${tail})
`);
  }
}

// `rb.<src>.<twin>`: a record taken out of a red-black tree that `insert` built (`balance` answers the
// recursive insert's tree at two of its levels, kernel §4.4, *Two readings through a later root*) and its
// list pushed in place. `<src>`: `distinct` (three records), `param` (handed by a caller), `many` (seven
// records, rotations at several depths), `replace` (one key inserted twice: the first record leaves the
// tree), `shared` (one record at two keys), `sharedeep` (one record at the first and the last of seven keys).
// `<twin>`: `dead` (nothing read after), `live` (the list pushed, read again out of the tree after) or
// `held` (the record that the main bound and handed to the tree, read after: unsafe where it is the one
// pushed or shares its list, safe for `replace` and `many`).
const RB = "import List\nimport Node exposing (Program)\nimport String\n\n\ntype alias R =\n    n : Int\n    xs : List Int\n\n\ntype NColor\n    = Red\n    | Black\n\n\ntype Tree\n    = Node NColor Int R Tree Tree\n    | Leaf\n\n\ninsert : Tree, Int, R → Tree\ninsert tree key value =\n    case tree of\n        Leaf →\n            Node Red key value Leaf Leaf\n\n        Node nColor nKey nValue nLeft nRight →\n            if key < nKey then\n                balance nColor nKey nValue (insert nLeft key value) nRight\n            else if key == nKey then\n                Node nColor nKey value nLeft nRight\n            else\n                balance nColor nKey nValue nLeft (insert nRight key value)\n\n\nbalance : NColor, Int, R, Tree, Tree → Tree\nbalance color key value left right =\n    case right of\n        Node Red rK rV rLeft rRight →\n            case left of\n                Node Red lK lV lLeft lRight →\n                    Node\n                        Red\n                        key\n                        value\n                        (Node Black lK lV lLeft lRight)\n                        (Node Black rK rV rLeft rRight)\n\n                _ →\n                    Node color rK rV (Node Red key value left rLeft) rRight\n\n        _ →\n            case left of\n                Node Red lK lV (Node Red llK llV llLeft llRight) lRight →\n                    Node\n                        Red\n                        lK\n                        lV\n                        (Node Black llK llV llLeft llRight)\n                        (Node Black key value lRight right)\n\n                _ →\n                    Node color key value left right\n\n\nget : Tree, Int → Maybe R\nget tree k =\n    case tree of\n        Leaf →\n            Nothing\n\n        Node _ nk v l r →\n            if k < nk then\n                get l k\n            else if k == nk then\n                Just v\n            else\n                get r k\n\n\npushAt : Tree, Int → List Int\npushAt tree k =\n    case get tree k of\n        Just v →\n            List.push v.xs 9\n\n        Nothing →\n            []\n\n\n";
const RBS = {
  distinct: ['t = build r1 { n = 2, xs = [ 2 ] } r3', '1', 'r1'],
  param: ['t = build r1 r2 r3', '2', 'r2'],
  many: ['t = List.foldl [ 4, 2, 6, 1, 3, 5, 7 ] Leaf λk acc → insert acc k { n = k, xs = [ k ] }', '5', 'r1'],
  replace: ['t = insert (build r1 r2 r3) 2 { n = 9, xs = [ 9 ] }', '2', 'r2'],
  shared: ['t = build r1 r2 r1', '1', 'r1'],
  sharedeep: ['t = List.foldl [ 2, 3, 4, 5, 6 ] (insert (insert Leaf 1 r1) 7 r1) λk acc → insert acc k { n = k, xs = [ k ] }', '7', 'r1'],
};
for (const [k, [mk, key, other]] of Object.entries(RBS)) {
  for (const twin of ['dead', 'live', 'held']) {
    const tail = twin === 'live' ? `"\${show (pushAt t ${key})} \${show (listAt t ${key})}"` : twin === 'held' ? `"\${show (pushAt t ${key})} \${show ${other}.xs}"` : `show (pushAt t ${key})`;
    add(`rb.${k}.${twin}`, `${RB}
show : List Int → String
show l = String.join (List.map l String.fromInt) ","


build : R, R, R → Tree
build a b c = insert (insert (insert Leaf 1 a) 2 b) 3 c


listAt : Tree, Int → List Int
listAt t k = Maybe.withDefault (Maybe.map (get t k) λv → v.xs) []


main : Program
main =
    r1 = { n = 1, xs = [ 1 ] }
    r2 = { n = 2, xs = [ 2 ] }
    r3 = { n = 3, xs = [ 3 ] }
    ${mk}
    Node.print (${tail})
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
