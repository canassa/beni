// cells.mjs <outdir> [filter]: a generator for the contents of a `Ref` written in place, across fibers
// and parks (research report 165). A program puts a value in a cell (a `List Int`, a record of a
// list and a number, or a `Dict Int (List Int)`), keeps an old value of the contents in a holder, writes
// the contents in place by one of the cell's writers, then reads the holder. In place the holder and the
// cell's new contents are one object, so a read of the holder after the write sees the new value: the
// checker must refuse it, or the outputs must agree. The writer and the reader can be two fibers, with a
// park between the take and the read.
//
// Programs are `<contents>.<maker>.<writer>.<reader>.<holder>.<fibers>.<twin>/Main.beni`:
//
// - contents: `list`, `record`, `dict`;
// - maker: `local` (the function that reads makes the cell) or `param` (`main` makes it and hands it);
// - writer: `upd` (`Ref.update` with a function that writes its parameter), `mod` (`Ref.modify`),
//   `getSet` (`Ref.set r (w (Ref.get r))`), `helper` (a function that takes the cell and updates it),
//   `getW` (a write of what `Ref.get` answered, not put back: the cell still holds the written value);
// - reader: `none` (nothing old is read after the write), `cell` (`Ref.get r` after the write), `loan`
//   (a value `Ref.get` answered before the write, read after it), `stored` (the value the cell was made
//   with, read after the write);
// - holder: where the loan is kept (`name`, `tuple`, `closure`); `-` for the other readers;
// - fibers: `same` (one fiber, no park), `parkSelf` (one fiber, a park between the take and the write),
//   `park` (the reader in one fiber takes, parks and reads; the writer in another writes while it is
//   parked), `writer` (the write in a spawned fiber that the reader joins).
//
// The twin is `live` when the reader reads an old value after the write (a `loan` or `stored` reader, and
// the `cell` reader of `getW`), `dead` otherwise. A refusal of a `dead` twin is a precision loss; a TRAP or
// DIFF of any program is a soundness hole. See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/cells.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

// The type of the contents, a first value, a write of `v` that answers its new value, and a reader.
const CONTENTS = {
  list: { t: 'List Int', init: '[ 1, 2 ]', w: (v) => `List.push ${v} 5`, show: 'ints' },
  record: { t: 'R', init: '{ items = [ 1 ], n = 0 }', w: (v) => `{ ${v} | n = ${v}.n + 1 }`, show: 'showR' },
  dict: { t: 'Dict Int (List Int)', init: 'Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]', w: (v) => `Dict.insert ${v} 3 [ 30 ]`, show: 'render' },
};

// A writer: the lines that write the contents of `r`, and the text they leave to print.
const WRITERS = {
  upd: (c) => ({ lines: [`Ref.update r λv → ${c.w('v')}`], shown: '"u"' }),
  mod: (c) => ({ lines: [`k = Ref.modify r λv → ( 7, ${c.w('v')} )`], shown: 'String.fromInt k' }),
  getSet: (c) => ({ lines: [`Ref.set r (${c.w('(Ref.get r)')})`], shown: '"s"' }),
  helper: () => ({ lines: ['bump r'], shown: '"h"' }),
  getW: (c) => ({ lines: [`w = ${c.w('(Ref.get r)')}`], shown: `${c.show} w` }),
};

// A holder of the loan `old`: the line that keeps it, and the expression that reads it back.
const HOLDERS = {
  name: { pre: null, get: 'old' },
  tuple: { pre: 'h = ( old, 1 )', get: 'fstOf h' },
  closure: { pre: 'h = λ⊤ → old', get: 'h ⊤' },
};

const READERS = ['none', 'cell', 'loan', 'stored'];
const FIBERS = ['same', 'parkSelf', 'park', 'writer'];

function isLive(writer, reader) {
  if (reader === 'loan' || reader === 'stored') return true;
  return reader === 'cell' && writer === 'getW';
}

function gen(cname, maker, writer, reader, holder, fibers) {
  const c = CONTENTS[cname];
  const wr = WRITERS[writer](c);
  const h = HOLDERS[holder];
  // What the reader prints after the write.
  const readOld = reader === 'loan' ? `${c.show} (${h.get})` : reader === 'stored' ? `${c.show} v0` : reader === 'cell' ? `${c.show} (Ref.get r)` : '"-"';
  const take = reader === 'loan' ? ['old = Ref.get r', ...(h.pre ? [h.pre] : [])] : [];
  const lines = [];
  if (maker === 'local') lines.push(`v0 = ${c.init}`, 'r = Ref.make v0');
  if (fibers === 'same') {
    lines.push(...take, ...wr.lines, `[ ${wr.shown}, ${readOld} ]`);
  } else if (fibers === 'parkSelf') {
    lines.push(...take, 'Io.sleep 1', ...wr.lines, `[ ${wr.shown}, ${readOld} ]`);
  } else if (fibers === 'park') {
    // The reader takes, parks and reads; the writer writes while the reader is parked.
    const readerBody = [...take, 'Io.sleep 5', readOld];
    const writerBody = ['Io.sleep 1', ...wr.lines, wr.shown];
    lines.push(`a = Task.spawn λ⊤ →\n${ind(readerBody.join('\n'), 4)}`);
    lines.push(`b = Task.spawn λ⊤ →\n${ind(writerBody.join('\n'), 4)}`);
    lines.push('ra = Task.join a', 'rb = Task.join b', '[ rb, ra ]');
  } else {
    // The write in a fiber that the reader joins.
    lines.push(...take, `b = Task.spawn λ⊤ →\n${ind([...wr.lines, wr.shown].join('\n'), 4)}`, 'rb = Task.join b', `[ rb, ${readOld} ]`);
  }
  const sig = maker === 'local' ? `go : ⊤ → List String\ngo ⊤ =` : `go : Ref ${/ /.test(c.t) ? `(${c.t})` : c.t}, ${c.t} → List String\ngo r v0 =`;
  const call = maker === 'local' ? 'go ⊤' : `go (Ref.make v0) v0`;
  const mainBody = maker === 'local' ? `Node.printLines (${call})` : `v0 = ${c.init}\n    Node.printLines (${call})`;
  const refT = /\s/.test(c.t) ? `(${c.t})` : c.t;
  return `-- ${cname}.${maker}.${writer}.${reader}.${holder}.${fibers}: see bench/ownership-sweeps/cells.mjs.
import Dict exposing (Dict)
import Io
import Node exposing (Program)
import Ref exposing (Ref)
import Task


type alias R =
    { items : List Int, n : Int }


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


showR : R → String
showR s = "\${String.fromInt s.n}:\${ints s.items}"


render : Dict Int (List Int) → String
render d = String.join (List.map (Dict.toList d) λ( k, v ) → "\${String.fromInt k}=\${ints v}") ";"


fstOf : a × Int → a
fstOf ( a, _ ) = a


${writer === 'helper' ? `bump : Ref ${refT} → ⊤\nbump r = Ref.update r λv → ${c.w('v')}\n\n\n` : ''}${sig}
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ →
    ${mainBody}
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
const emit = (name, files) => {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(files)) fs.writeFileSync(path.join(d, f), text);
  list.push(path.resolve(d));
};
for (const cname of Object.keys(CONTENTS)) for (const maker of ['local', 'param']) for (const writer of Object.keys(WRITERS)) for (const reader of READERS) for (const holder of reader === 'loan' ? Object.keys(HOLDERS) : ['-']) for (const fibers of FIBERS) {
  const twin = isLive(writer, reader) ? 'live' : 'dead';
  emit(`${cname}.${maker}.${writer}.${reader}.${holder}.${fibers}.${twin}`, { 'Main.beni': gen(cname, maker, writer, reader, holder, fibers) });
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
