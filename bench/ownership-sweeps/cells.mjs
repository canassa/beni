// cells.mjs <outdir> [filter]: a generator for the contents of a `Ref` written in place, across fibers
// and parks (research report 165). A program puts a value in a cell (a `List Int`, a record of a
// list and a number, a `Dict Int (List Int)`, or a pair of lists), keeps an old value of the contents in a holder, writes
// the contents in place by one of the cell's writers, then reads the holder. In place the holder and the
// cell's new contents are one object, so a read of the holder after the write sees the new value: the
// checker must refuse it, or the outputs must agree. The writer and the reader can be two fibers, with a
// park between the take and the read.
//
// Programs are `<contents>.<maker>.<writer>.<reader>.<holder>.<fibers>.<twin>/Main.beni`:
//
// - contents: `list`, `record`, `dict`, `pair` (its first part written in place);
// - maker: `local` (the function that reads makes the cell) or `param` (`main` makes it and hands it);
// - writer: `upd` (`Ref.update` with a function that writes its parameter), `mod` (`Ref.modify`),
//   `getSet` (`Ref.set r (w (Ref.get r))`), `helper` (a function that takes the cell and updates it),
//   `getW` (a write of what `Ref.get` answered, not put back: the cell still holds the written value);
//   a closure that captured the handle and updates the cell (kernel §13 item 11): `clos` (called
//   directly), `closApply` (handed to a function that calls it), `closMap` (run by `List.map`),
//   `closScope` (run by `Task.scope`); `closTwice` (run twice by a helper), `closTwiceStore` and
//   `closTwiceStoreDead` (the same, storing a captured value after the update, which is read after or
//   not), `closWrap` (handed to a helper that answers a wrapper of it, which the frame calls) and
//   `closOther` (a second cell holds the contents, which the frame writes before a closure updates the
//   second cell; #2586);
// - reader: `none` (nothing old is read after the write), `cell` (`Ref.get r` after the write), `loan`
//   (a value `Ref.get` answered before the write, read after it), `stored` (the value the cell was made
//   with, read after the write), `mid` (a value `Ref.get` answered between two writes, read after the
//   second), `name2` (a loan taken before the write through a second name of the handle, one a callee
//   answers beside a number, read after it), `name2cell` (`Ref.get` through that second name after the
//   write: dead), `store2` (a value stored through that second name before the write, read after it),
//   `storeK` (the same, stored by a closure that captured the handle; research report 166); `part0` and
//   `part1` (`pair` only: one part taken out before the write and read after, the written part or the
//   other one; #2583);
// - holder: where the loan is kept (`name`, `tuple`, `closure`, `list`; `listLen`, a list read after by
//   `List.length` alone: its own array, #2584); `-` for the other readers;
// - fibers: `same` (one fiber, no park), `parkSelf` (one fiber, a park between the take and the write),
//   `park` (the reader in one fiber takes, parks and reads; the writer in another writes while it is
//   parked), `writer` (the write in a spawned fiber that the reader joins); `par` and `scoped` (the
//   reader and the writer of `park` as `Task.par`'s halves, or two fibers of one `Task.scope`),
//   `bracket` (the write as `Task.bracket`'s body), `race` (the write as the half of `Task.race` that
//   finishes first), `deferred` (the writer fiber waits on a `Deferred`
//   the reader completes after its take), `queue` (the handle goes to the writer fiber through a
//   `Queue`), `parkLater` (`park` with the writer's fiber spawned first), `peek` (the writer's fiber,
//   then a helper that takes a value out of the cell, parks and reads it), `getter` (the same through a
//   function the helper is handed, which answers a value taken out of the cell), `generic` (the same through a generic helper
//   handed the cell at a type variable; kernel §13 item 12).
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
  // A pair of lists whose first part is written in place (#2583: a part of a root reads its own entries).
  pair: { t: 'List Int × List Int', init: '( [ 1 ], [ 2 ] )', w: (v) => `( List.push ${v}.0 5, ${v}.1 )`, show: 'showP' },
};

// A writer: the lines that write the contents of `r`, and the text they leave to print.
const WRITERS = {
  upd: (c, s = '') => ({ lines: [`Ref.update r λv → ${c.w('v')}`], shown: '"u"' }),
  mod: (c, s = '') => ({ lines: [`k${s} = Ref.modify r λv → ( 7, ${c.w('v')} )`], shown: 'String.fromInt k' }),
  getSet: (c, s = '') => ({ lines: [`Ref.set r (${c.w('(Ref.get r)')})`], shown: '"s"' }),
  helper: (c, s = '') => ({ lines: ['bump r'], shown: '"h"' }),
  getW: (c, s = '') => ({ lines: [`w${s} = ${c.w('(Ref.get r)')}`], shown: `${c.show} w` }),
  clos: (c, s = '') => ({ lines: [`wr${s} = λ⊤ → Ref.update r λv → ${c.w('v')}`, `wr${s} ⊤`], shown: '"c"' }),
  closApply: (c, s = '') => ({ lines: [`apply λ⊤ → Ref.update r λv → ${c.w('v')}`], shown: '"a"' }),
  closMap: (c, s = '') => ({ lines: [`_ = List.map [ 1 ] λ_ → Ref.update r λv → ${c.w('v')}`], shown: '"m"' }),
  closScope: (c, s = '') => ({ lines: [`Task.scope λ_ → Ref.update r λv → ${c.w('v')}`], shown: '"o"' }),
  // #2586: a closure `twice` runs, which stores a captured value after its update (read after: live;
  // unread: by the reader), a wrapper of the closure that a callee answers, and a second cell that holds
  // the contents, written by the frame before a closure `apply` runs updates it.
  closTwice: (c, s = '') => ({ lines: [`twice λ⊤ → Ref.update r λv → ${c.w('v')}`], shown: '"t"' }),
  closTwiceStore: (c, s = '') => ({ lines: [`v9${s} = ${c.init}`, `twice λ⊤ →\n    Ref.update r λv → ${c.w('v')}\n    Ref.set r v9${s}`], shown: `${c.show} v9${s}` }),
  closTwiceStoreDead: (c, s = '') => ({ lines: [`v9${s} = ${c.init}`, `twice λ⊤ →\n    Ref.update r λv → ${c.w('v')}\n    Ref.set r v9${s}`], shown: '"d"' }),
  closWrap: (c, s = '') => ({ lines: [`g${s} = wrapFn λx →\n    Ref.update r λv → ${c.w('v')}\n    x`, `_ = g${s} 1`], shown: '"w"' }),
  closOther: (c, s = '') => ({ lines: [`r9${s} = Ref.make (${c.init})`, `Ref.set r9${s} (Ref.get r)`, `Ref.update r λv → ${c.w('v')}`, `apply λ⊤ → Ref.update r9${s} λv → ${c.w('v')}`], shown: `${c.show} (Ref.get r9${s})` }),
};

// A holder of the loan `old`: the line that keeps it, and the expression that reads it back.
const HOLDERS = {
  name: { pre: null, get: 'old' },
  tuple: { pre: 'h = ( old, 1 )', get: 'fstOf h' },
  closure: { pre: 'h = λ⊤ → old', get: 'h ⊤' },
  // A list that holds the loan, read after the write by `List.length` alone (its own array: dead, #2584)
  // or through its element (live).
  listLen: { pre: 'h = [ old ]', get: null, len: true },
  list: { pre: 'h = [ old ]', get: 'firstOr h old' },
};

const READERS = ['none', 'cell', 'loan', 'stored', 'mid', 'name2', 'name2cell', 'store2', 'storeK', 'part0', 'part1'];
// `part0` and `part1` take one part of a pair out of the cell before the write and read it after: the
// written first part (live) or the second, which no write touches (dead).
const PART_READERS = ['part0', 'part1'];
const FIBERS = ['same', 'parkSelf', 'park', 'writer', 'par', 'scoped', 'bracket', 'deferred', 'queue', 'parkLater', 'peek', 'getter', 'generic', 'race'];

function isLive(writer, reader, fibers, holder) {
  if (reader === 'part1') return writer === 'closTwiceStore' || writer === 'closOther' || ((fibers === 'peek' || fibers === 'getter' || fibers === 'generic') && writer !== 'getW');
  if (reader === 'part0') return true;
  if (reader === 'loan' && holder === 'listLen') return writer === 'closTwiceStore' || writer === 'closOther' || ((fibers === 'peek' || fibers === 'getter' || fibers === 'generic') && writer !== 'getW');
  // `peek`'s helper reads a value it took before its park, while the writer writes.
  if ((fibers === 'peek' || fibers === 'getter' || fibers === 'generic') && writer !== 'getW') return true;
  if (writer === 'closTwiceStore' || writer === 'closOther') return true;
  if (reader === 'loan' || reader === 'stored' || reader === 'mid' || reader === 'name2' || reader === 'store2' || reader === 'storeK') return true;
  if (reader === 'name2cell') return writer === 'getW';
  return reader === 'cell' && writer === 'getW';
}

function gen(cname, maker, writer, reader, holder, fibers) {
  const c = CONTENTS[cname];
  const wr = WRITERS[writer](c);
  const h = HOLDERS[holder];
  // What the reader prints after the write.
  const readOld = reader === 'loan' ? (h.len ? 'String.fromInt (List.length h)' : `${c.show} (${h.get})`) : reader === 'part0' || reader === 'part1' ? 'ints old' : reader === 'stored' ? `${c.show} v0` : reader === 'cell' ? `${c.show} (Ref.get r)` : reader === 'mid' || reader === 'name2' ? `${c.show} old` : reader === 'store2' || reader === 'storeK' ? `${c.show} v1` : reader === 'name2cell' ? `${c.show} (Ref.get r2)` : '"-"';
  const take = reader === 'loan' ? ['old = Ref.get r', ...(h.pre ? [h.pre] : [])] : reader === 'part0' ? ['( old, _ ) = Ref.get r'] : reader === 'part1' ? ['( _, old ) = Ref.get r'] : reader === 'mid' ? [...WRITERS[writer](c, '1').lines, 'old = Ref.get r'] : reader === 'name2' ? ['( r2, _ ) = withHandle r', 'old = Ref.get r2'] : reader === 'name2cell' ? ['( r2, _ ) = withHandle r'] : reader === 'store2' ? ['( r2, _ ) = withHandle r', `v1 = ${c.init}`, 'Ref.set r2 v1'] : reader === 'storeK' ? [`v1 = ${c.init}`, 'put1 = λ⊤ → Ref.set r v1', 'put1 ⊤'] : [];
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
  } else if (fibers === 'parkLater') {
    // `park` with the writer's fiber spawned first: the reader's fiber holds the cell after it.
    const readerBody = [...take, 'Io.sleep 5', readOld];
    const writerBody = ['Io.sleep 1', ...wr.lines, wr.shown];
    lines.push(`b = Task.spawn λ⊤ →\n${ind(writerBody.join('\n'), 4)}`);
    lines.push(`a = Task.spawn λ⊤ →\n${ind(readerBody.join('\n'), 4)}`);
    lines.push('ra = Task.join a', 'rb = Task.join b', '[ rb, ra ]');
  } else if (fibers === 'peek') {
    // The writer's fiber spawned, then a helper that takes a value out of the cell, parks and reads it.
    lines.push(`b = Task.spawn λ⊤ →\n${ind(['Io.sleep 1', ...wr.lines, wr.shown].join('\n'), 4)}`, 'ra = peek r', 'rb = Task.join b', '[ rb, ra ]');
  } else if (fibers === 'generic') {
    // `peek` through a generic helper handed the cell at a type variable.
    lines.push(`b = Task.spawn λ⊤ →\n${ind(['Io.sleep 1', ...wr.lines, wr.shown].join('\n'), 4)}`, 'ra = holdAt r λh → Ref.get h', 'rb = Task.join b', '[ rb, ra ]');
  } else if (fibers === 'getter') {
    // `peek` through a function that answers a value taken out of the cell.
    lines.push(`b = Task.spawn λ⊤ →\n${ind(['Io.sleep 1', ...wr.lines, wr.shown].join('\n'), 4)}`, 'ra = peekWith λ⊤ → Ref.get r', 'rb = Task.join b', '[ rb, ra ]');
  } else if (fibers === 'par') {
    // The reader and the writer as the two halves of `Task.par`.
    const readerBody = [...take, 'Io.sleep 5', readOld];
    const writerBody = ['Io.sleep 1', ...wr.lines, wr.shown];
    lines.push(`( ra, rb ) = Task.par\n    (λ⊤ →\n${ind(readerBody.join('\n'), 8)}\n    )\n    λ⊤ →\n${ind(writerBody.join('\n'), 8)}`, '[ rb, ra ]');
  } else if (fibers === 'scoped') {
    // The reader and the writer as two fibers of one `Task.scope`.
    const readerBody = [...take, 'Io.sleep 5', readOld];
    const writerBody = ['Io.sleep 1', ...wr.lines, wr.shown];
    lines.push(`Task.scope λs →\n    a = Task.spawnIn s λ⊤ →\n${ind(readerBody.join('\n'), 8)}\n    b = Task.spawnIn s λ⊤ →\n${ind(writerBody.join('\n'), 8)}\n    ra = Task.join a\n    rb = Task.join b\n    [ rb, ra ]`);
  } else if (fibers === 'race') {
    // The write as the half of `Task.race` that finishes first; the other half sleeps and is cancelled.
    lines.push(...take, `rb = Task.race\n    (λ⊤ →\n${ind(['Io.sleep 1', ...wr.lines, wr.shown].join('\n'), 8)}\n    )\n    λ⊤ →\n        Io.sleep 40\n        "late"`, `[ rb, ${readOld} ]`);
  } else if (fibers === 'bracket') {
    // The write as the body of `Task.bracket`.
    lines.push(...take, `rb = Task.bracket (λ⊤ → ⊤) (λ_ _ → ⊤) λ_ →\n${ind([...wr.lines, wr.shown].join('\n'), 4)}`, `[ rb, ${readOld} ]`);
  } else if (fibers === 'deferred') {
    // The writer waits on a `Deferred` that the reader completes after its take.
    lines.push('d = Deferred.make ⊤', `b = Task.spawn λ⊤ →\n${ind(['Deferred.wait d', ...wr.lines, wr.shown].join('\n'), 4)}`, ...take, '_ = Deferred.complete d ⊤', 'Io.sleep 1', 'rb = Task.join b', `[ rb, ${readOld} ]`);
  } else if (fibers === 'queue') {
    // The handle goes through a `Queue` to the writer's fiber.
    lines.push('q = Queue.unbounded ⊤', '_ = Queue.offer q r', ...take, 'b = Task.spawn λ⊤ → fromQueue q', 'rb = Task.join b', `[ rb, ${readOld} ]`);
  } else {
    // The write in a fiber that the reader joins.
    lines.push(...take, `b = Task.spawn λ⊤ →\n${ind([...wr.lines, wr.shown].join('\n'), 4)}`, 'rb = Task.join b', `[ rb, ${readOld} ]`);
  }
  const holdAt = fibers === 'generic' ? `holdAt : a, (a → ${c.t}) → String\nholdAt x g =\n    old = g x\n    Io.sleep 5\n    ${c.show} old\n\n\n` : '';
  const peekWith = fibers === 'getter' ? `peekWith : (⊤ → ${c.t}) → String\npeekWith g =\n    old = g ⊤\n    Io.sleep 5\n    ${c.show} old\n\n\n` : '';
  const peek = fibers === 'peek' ? `peek : Ref ${/\s/.test(c.t) ? `(${c.t})` : c.t} → String\npeek h =\n    old = Ref.get h\n    Io.sleep 5\n    ${c.show} old\n\n\n` : '';
  const fromQueue = fibers === 'queue' ? `fromQueue : Queue (Ref ${/\s/.test(c.t) ? `(${c.t})` : c.t}) → String\nfromQueue q =\n    case Queue.take q of\n        Just r →\n${ind([...wr.lines, wr.shown].join('\n'), 12)}\n\n        Nothing →\n            "-"\n\n\n` : '';
  const sig = maker === 'local' ? `go : ⊤ → List String\ngo ⊤ =` : `go : Ref ${/ /.test(c.t) ? `(${c.t})` : c.t}, ${c.t} → List String\ngo r v0 =`;
  const call = maker === 'local' ? 'go ⊤' : `go (Ref.make v0) v0`;
  const mainBody = maker === 'local' ? `Node.printLines (${call})` : `v0 = ${c.init}\n    Node.printLines (${call})`;
  const refT = /\s/.test(c.t) ? `(${c.t})` : c.t;
  return `-- ${cname}.${maker}.${writer}.${reader}.${holder}.${fibers}: see bench/ownership-sweeps/cells.mjs.
import Deferred
import Dict exposing (Dict)
import Io
import Node exposing (Program)
import Queue exposing (Queue)
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


firstOr : List a, a → a
firstOr xs d =
    case xs of
        [ x, …_ ] →
            x

        [] →
            d


showP : List Int × List Int → String
showP p = "\${ints p.0}/\${ints p.1}"


withHandle : Ref a → Ref a × Int
withHandle h = ( h, 1 )


apply : (⊤ → ⊤) → ⊤
apply g = g ⊤


twice : (⊤ → ⊤) → ⊤
twice f =
    f ⊤
    f ⊤


wrapFn : (Int → Int) → (Int → Int)
wrapFn f = λx → f x


${fromQueue}${peek}${peekWith}${holdAt}${writer === 'helper' ? `bump : Ref ${refT} → ⊤\nbump r = Ref.update r λv → ${c.w('v')}\n\n\n` : ''}${sig}
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
  if (PART_READERS.includes(reader) && cname !== 'pair') continue;
  const twin = isLive(writer, reader, fibers, holder) ? 'live' : 'dead';
  emit(`${cname}.${maker}.${writer}.${reader}.${holder}.${fibers}.${twin}`, { 'Main.beni': gen(cname, maker, writer, reader, holder, fibers) });
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
