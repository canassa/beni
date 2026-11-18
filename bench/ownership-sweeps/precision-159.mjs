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
