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
//   second cell; #2586); a closure or local function that stores a new value into the cell it captured on
//   a way its body does not take, then an update (#2590: kernel §13 items 3, 6 and 11): `condIf` (an `if`
//   with no `else`), `condCase` (a `case` arm), `condAnd` (`&&`), `condTry` (a `?` before the store),
//   `condLocal` (a local function with a parameter), `condHelper` (a helper that closes over its
//   parameter's cell), `condInner`, `condApply` and `condScope` (the store and the update in one closure,
//   called directly, by `apply`, by `Task.scope`) and `condBoth` (two arms that both store: dead); these
//   run with the readers `none`, `cell`, `loan` (held by `name` or `closure`), `stored` and `mid`, and
//   every fiber shape but `getter` and `generic`; a writer that stores a new value, parks, and writes it in
//   place (#2591): `storePark` (`Task.yieldNow`), `storeSleep` (`Io.sleep`), `storeNew` (an update that
//   answers a new value) and `storeHelper` (a helper over its parameter's cell), with the readers `none`,
//   `cell`, `loan` (`name`, `closure`) and `stored`; the frame's own write in an arm that runs, then a
//   read after the `if` or `case` (#2594): `armIf`, `armElse`, `armBoth`, `armCase`, `armVal`, `armMod`
//   and `armHelper`, live where `upd` is, with the readers `none`, `cell`, `loan` (`name`, `closure`,
//   `list`), `stored`, `mid`, `name2`, `name2cell`, `part0` and `part1`; a body whose arms leave one cell at
//   another place each, then the write of the first part (`pair` only; kernel §13 item 5): `moveOn` (a
//   helper's arm that moves the first part to the second and copies the second in its place: dead),
//   `moveOff` (its other arm, which leaves the pair: live where `upd` is), `moveDirect` (`moveOn` in the
//   frame) and `moveAlias` (an arm that puts the first part at both places, the pair read after: live),
//   with the readers `none`, `cell`, `loan` (`name`, `closure`, `list`), `stored`, `mid`, `part0`, `part1`;
//   a helper whose `case` arms are paths its caller tells apart (`pair` only; kernel §13 item 13):
//   `pathsMove` (its moving arm, then its writing arm, then the frame's write: dead), `pathsChain` (the
//   two three times: dead) and `pathsAlias` (an arm that puts the first part at both places, then its
//   writing arm, the pair read after: live), with the same readers;
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
//   handed the cell at a type variable; kernel §13 item 12), `midPark` (the writer's fiber spawned; the
//   frame parks, takes a loan of the cell while the writer is parked, and reads it after the join; #2591;
//   with the reader `loan` held by `name` only).
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
  // #2590: a closure or local function stores a new value into the cell it captured on one way of its
  // body only (the condition is false when it runs), then the cell is updated: an `if` with no `else`, a
  // `case` arm, `&&`, a `?` before the store, a local function with a parameter, a helper that closes over
  // its parameter's cell, the store and the update inside one closure (called directly, by `apply`, by
  // `Task.scope`), and two arms that both store (`condBoth`: the old contents are never written).
  condIf: (c, s = '') => ({ lines: [`st${s} = λ⊤ → if off 1 then Ref.set r (${c.init}) else ⊤`, `st${s} ⊤`, `Ref.update r λv → ${c.w('v')}`], shown: '"i"' }),
  condCase: (c, s = '') => ({ lines: [`st${s} = λ⊤ →\n    case List.length [ 1 ] of\n        0 → Ref.set r (${c.init})\n        _ → ⊤`, `st${s} ⊤`, `Ref.update r λv → ${c.w('v')}`], shown: '"k"' }),
  condAnd: (c, s = '') => ({ lines: [`st${s} = λ⊤ → off 1 && storeB r (${c.init})`, `_ = st${s} ⊤`, `Ref.update r λv → ${c.w('v')}`], shown: '"n"' }),
  condTry: (c, s = '') => ({ lines: [`st${s} : ⊤ → Result String ⊤`, `st${s} ⊤ =\n    stepOk 1?\n    Ref.set r (${c.init})\n    Ok ⊤`, `_ = st${s} ⊤`, `Ref.update r λv → ${c.w('v')}`], shown: '"y"' }),
  condLocal: (c, s = '') => ({ lines: [`st${s} on = if on then Ref.set r (${c.init}) else ⊤`, `st${s} (off 1)`, `Ref.update r λv → ${c.w('v')}`], shown: '"l"' }),
  condHelper: (c, s = '') => ({ lines: [`storeIf r (off 1) (${c.init})`, `Ref.update r λv → ${c.w('v')}`], shown: '"e"' }),
  condInner: (c, s = '') => ({ lines: [`st${s} = λ⊤ →\n    if off 1 then Ref.set r (${c.init}) else ⊤\n    Ref.update r λv → ${c.w('v')}`, `st${s} ⊤`], shown: '"j"' }),
  condApply: (c, s = '') => ({ lines: [`apply λ⊤ →\n    if off 1 then Ref.set r (${c.init}) else ⊤\n    Ref.update r λv → ${c.w('v')}`], shown: '"p"' }),
  condScope: (c, s = '') => ({ lines: [`Task.scope λ_ →\n    if off 1 then Ref.set r (${c.init}) else ⊤\n    Ref.update r λv → ${c.w('v')}`], shown: '"q"' }),
  storePark: (c, s = '') => ({ lines: [`Ref.set r (${c.init})`, 'Task.yieldNow ⊤', `Ref.update r λv → ${c.w('v')}`], shown: '"sp"' }),
  storeSleep: (c, s = '') => ({ lines: [`Ref.set r (${c.init})`, 'Io.sleep 2', `Ref.update r λv → ${c.w('v')}`], shown: '"ss"' }),
  storeNew: (c, s = '') => ({ lines: [`Ref.update r λ_ → ${c.init}`, 'Task.yieldNow ⊤', `Ref.update r λv → ${c.w('v')}`], shown: '"sn"' }),
  storeHelper: (c, s = '') => ({ lines: ['storeThenPark r'], shown: '"sh"' }),
  condBoth: (c, s = '') => ({ lines: [`st${s} = λ⊤ → if off 1 then Ref.set r (${c.init}) else Ref.set r (${c.init})`, `st${s} ⊤`, `Ref.update r λv → ${c.w('v')}`], shown: '"b"' }),
  // #2594: the frame writes the contents in place in an arm that runs, then reads after the `if` or
  // `case`: `armIf` (an `if` with no `else`), `armElse` (the `else` arm), `armBoth` (both arms),
  // `armCase` (a `case` arm), `armVal` (an `if` that gives a value), `armMod` (`Ref.modify` in a
  // value-giving arm), `armHelper` (a helper that updates its parameter's cell, in an arm). Each is
  // live where `upd` is.
  armIf: (c, s = '') => ({ lines: [`if on 1 then\n    Ref.update r λv → ${c.w('v')}`], shown: '"ai"' }),
  armElse: (c, s = '') => ({ lines: [`if off 1 then\n    ⊤\nelse\n    Ref.update r λv → ${c.w('v')}`], shown: '"ae"' }),
  armBoth: (c, s = '') => ({ lines: [`if on 1 then\n    Ref.update r λv → ${c.w('v')}\nelse\n    Ref.update r λv → ${c.w('v')}`], shown: '"ab"' }),
  armCase: (c, s = '') => ({ lines: [`case List.length [ 1 ] of\n    1 →\n        Ref.update r λv → ${c.w('v')}\n\n    _ →\n        ⊤`], shown: '"ac"' }),
  armVal: (c, s = '') => ({ lines: [`k${s} =\n    if on 1 then\n        Ref.update r λv → ${c.w('v')}\n        1\n\n    else\n        2`], shown: `String.fromInt k${s}` }),
  armMod: (c, s = '') => ({ lines: [`k${s} = if on 1 then Ref.modify r λv → ( 7, ${c.w('v')} ) else 3`], shown: `String.fromInt k${s}` }),
  armHelper: (c, s = '') => ({ lines: [`if on 1 then\n    bump r`], shown: '"ah"' }),
  // Blind round BN (kernel §13 item 5, *One value of the renewal at a time*): a body whose arms leave
  // one cell at another place each, then the frame's write of the first part (`pair` only). `moveOn`
  // runs the arm that moves the first part to the second and puts a copy of the second in its place
  // (a helper, `moveArm`), so the write is of the copy: dead; `moveOff` runs the arm that leaves the
  // pair as it was: live where `upd` is; `moveDirect` is `moveOn` written in the frame; `moveAlias`
  // runs an arm that puts the first part at both places, and reads the pair after: live.
  moveOn: (c, s = '') => ({ lines: ['moveArm r (on 1)', `Ref.update r λv → ${c.w('v')}`], shown: '"mo"' }),
  moveOff: (c, s = '') => ({ lines: ['moveArm r (off 1)', `Ref.update r λv → ${c.w('v')}`], shown: '"mf"' }),
  moveDirect: (c, s = '') => ({ lines: [`Ref.update r λv →\n    if on 1 then\n        ( List.copy v.1, v.0 )\n\n    else\n        v`, `Ref.update r λv → ${c.w('v')}`], shown: '"md"' }),
  moveAlias: (c, s = '') => ({ lines: ['aliasArm r (on 1)', `Ref.update r λv → ${c.w('v')}`], shown: 'showP (Ref.get r)' }),
  // Kernel §13 item 13: a helper whose `case` arms are paths its caller tells apart (`pair` only).
  // `pathArm` writes the first part in place on arm 0, moves it to the second on arm 1 and leaves the
  // pair on any other. `pathsMove` runs arm 1 then arm 0, then the frame writes the first part: each
  // write is of a new list, dead; `pathsChain` runs the two three times; `pathsAlias` runs
  // `aliasPathArm`'s arm that puts the first part at both places, then its writing arm, and reads the
  // pair after: live.
  pathsMove: (c, s = '') => ({ lines: ['pathArm r 1', 'pathArm r 0', `Ref.update r λv → ${c.w('v')}`], shown: '"pm"' }),
  pathsChain: (c, s = '') => ({ lines: ['pathArm r 1', 'pathArm r 0', 'pathArm r 1', 'pathArm r 0', 'pathArm r 1', 'pathArm r 0', `Ref.update r λv → ${c.w('v')}`], shown: '"pc"' }),
  pathsAlias: (c, s = '') => ({ lines: ['aliasPathArm r 2', 'aliasPathArm r 0', `Ref.update r λv → ${c.w('v')}`], shown: 'showP (Ref.get r)' }),
};
const MOVE = new Set(['moveOn', 'moveOff', 'moveDirect', 'moveAlias', 'pathsMove', 'pathsChain', 'pathsAlias']);
const MOVE_READERS = ['none', 'cell', 'loan', 'stored', 'mid', 'part0', 'part1'];
const MOVEHELPERS = `moveArm : Ref (List Int × List Int), Bool → ⊤
moveArm r b =
    Ref.update r λv →
        if b then
            ( List.copy v.1, v.0 )

        else
            v


aliasArm : Ref (List Int × List Int), Bool → ⊤
aliasArm r b =
    Ref.update r λv →
        if b then
            ( v.0, v.0 )

        else
            v


pathArm : Ref (List Int × List Int), Int → ⊤
pathArm r k =
    case k of
        0 →
            Ref.update r λv → ( List.push v.0 1, v.1 )

        1 →
            Ref.update r λv → ( [ 0 ], v.0 )

        _ →
            ⊤


aliasPathArm : Ref (List Int × List Int), Int → ⊤
aliasPathArm r k =
    case k of
        0 →
            Ref.update r λv → ( List.push v.0 1, v.1 )

        2 →
            Ref.update r λv → ( v.0, v.0 )

        _ →
            ⊤


`;
const ARM = new Set(['armIf', 'armElse', 'armBoth', 'armCase', 'armVal', 'armMod', 'armHelper']);
const ARM_READERS = ['none', 'cell', 'loan', 'stored', 'mid', 'name2', 'name2cell', 'part0', 'part1'];
const ARM_HOLDERS = ['name', 'closure', 'list'];
const ARM_FIBERS = ['same', 'parkSelf', 'park', 'writer', 'par', 'scoped', 'bracket', 'race', 'parkLater', 'peek', 'midPark'];
const ARMHELPERS = `on : Int → Bool
on k = k < 5


off : Int → Bool
off k = k > 5


`;
// The #2590 writers run over a part of the product: the readers and holders that hold the old contents,
// and the fiber shapes but `getter` and `generic`.
const COND = new Set(['condIf', 'condCase', 'condAnd', 'condTry', 'condLocal', 'condHelper', 'condInner', 'condApply', 'condScope', 'condBoth']);
const COND_READERS = ['none', 'cell', 'loan', 'stored', 'mid'];
const COND_HOLDERS = ['name', 'closure'];
const CONDHELPERS = `off : Int → Bool
off k = k > 5


stepOk : Int → Result String ⊤
stepOk k = if k > 5 then Ok ⊤ else Err "x"


storeB : Ref a, a → Bool
storeB h x =
    Ref.set h x
    True


storeIf : Ref a, Bool, a → ⊤
storeIf h b x =
    st = λ⊤ → if b then Ref.set h x else ⊤
    st ⊤


`;
// #2591: a writer that stores a new value into the cell, parks, then writes it in place: `storePark`
// (`Task.yieldNow`), `storeSleep` (`Io.sleep`), `storeNew` (an update that answers a new value) and
// `storeHelper` (a helper over its parameter's cell that does the three). With the fiber shape
// `midPark` a loan of the cell is taken while the writer's fiber is parked between its store and its write.
const STORE = new Set(['storePark', 'storeSleep', 'storeNew', 'storeHelper']);
const STORE_READERS = ['none', 'cell', 'loan', 'stored'];
const STORE_FIBERS = ['same', 'parkSelf', 'park', 'writer', 'par', 'scoped', 'bracket', 'race', 'parkLater', 'peek', 'midPark'];
const COND_FIBERS = ['same', 'parkSelf', 'park', 'writer', 'par', 'scoped', 'bracket', 'race', 'deferred', 'queue', 'parkLater', 'peek'];

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
const FIBERS = ['midPark', 'same', 'parkSelf', 'park', 'writer', 'par', 'scoped', 'bracket', 'deferred', 'queue', 'parkLater', 'peek', 'getter', 'generic', 'race'];

function isLive(writer, reader, fibers, holder) {
  // A write in an arm that runs is the write `upd` makes.
  if (ARM.has(writer)) writer = 'upd';
  // Both arms store a new value: the old contents are never written.
  if (writer === 'condBoth') return false;
  // The moving arm writes a copy that no holder has; the alias reads the pair after the write.
  if (writer === 'moveAlias' || writer === 'pathsAlias') return true;
  if (writer === 'moveOn' || writer === 'moveDirect' || writer === 'pathsMove' || writer === 'pathsChain') return false;
  if (writer === 'moveOff') writer = 'upd';
  // A loan taken while the writer is parked: the stored value, which a store-park-write writer writes.
  // (`closTwiceStore` and `closOther` write a value the reader holds in every shape.)
  if (fibers === 'midPark') return STORE.has(writer) || writer === 'closTwiceStore' || writer === 'closOther' || writer === 'closTwiceStoreDead';
  // A store-park-write writer writes the value it stored, which no other reader holds.
  if (STORE.has(writer)) return false;
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
  } else if (fibers === 'midPark') {
    // The writer's fiber spawned; the frame parks, takes a loan of the cell, and reads it after the join.
    lines.push(`b = Task.spawn λ⊤ →\n${ind([...wr.lines, wr.shown].join('\n'), 4)}`, 'Task.yieldNow ⊤', 'old = Ref.get r', 'rb = Task.join b', `[ rb, ${c.show} old ]`);
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


${COND.has(writer) ? CONDHELPERS : ''}${ARM.has(writer) || MOVE.has(writer) ? ARMHELPERS : ''}${MOVE.has(writer) ? MOVEHELPERS : ''}${writer === 'storeHelper' ? `storeThenPark : Ref ${refT} → ⊤\nstoreThenPark r =\n    Ref.set r (${c.init})\n    Task.yieldNow ⊤\n    Ref.update r λv → ${c.w('v')}\n\n\n` : ''}${fromQueue}${peek}${peekWith}${holdAt}${writer === 'helper' || writer === 'armHelper' ? `bump : Ref ${refT} → ⊤\nbump r = Ref.update r λv → ${c.w('v')}\n\n\n` : ''}${sig}
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ →
    ${mainBody}
`;
}

// #2595: a function answers a cell inside a `Maybe` or a `Result` after a `?` whose operand holds the
// contents' type, a `Maybe`/`Result` of another type than the answer. Programs are
// `try.<contents>.<wrap>.<op>.<site>.<use>.<twin>`: `wrap` the answer's `maybe` or `result`; `op` the
// operand (`fresh`, a new value; `arg`, the function's argument; `err`, `Result` only: the argument in
// `Err`, the answer `Result C (Ref Int)`); `site` where the `?` is (`top`, a `case` arm, a `local`
// function of a block, after a `park`, an `unannot` function); `use` what the caller does with the
// answer (`read` the cell; `argAfter`: update the cell, then read the argument; `writeArg`: write the
// argument in place, then read the answer; `fiber`: a spawned fiber updates the cell while the frame
// parks and reads the argument).
function tryLive(op, use) {
  if (op === 'arg') return use === 'argAfter' || use === 'writeArg' || use === 'fiber';
  if (op === 'err') return use === 'writeArg';
  return false;
}

function genTry(cname, wrap, op, site, use) {
  const c = CONTENTS[cname];
  const refT = /\s/.test(c.t) ? `(${c.t})` : c.t;
  const M = wrap === 'maybe' ? 'Maybe' : 'Result String';
  const OK = wrap === 'maybe' ? 'Just' : 'Ok';
  const inner = op === 'err' ? 'Int' : `(Ref ${refT})`;
  const ansT = op === 'err' ? `Result ${refT} (Ref Int)` : `${M} ${inner}`;
  const fail = op === 'err' ? `Err (${c.init})` : wrap === 'maybe' ? 'Nothing' : 'Err "z"';
  const operand = (a) => (op === 'fresh' ? 'src ⊤' : op === 'arg' ? `wrap ${a}` : `check ${a}`);
  const okc = op === 'err' ? 'Ok' : OK;
  const body = (a) => `x = (${operand(a)})?\n${okc} (Ref.make x)`;
  let fn;
  if (site === 'top') fn = `f : ${c.t} → ${ansT}\nf a =\n${ind(body('a'), 4)}`;
  else if (site === 'unannot') fn = `f a =\n${ind(body('a'), 4)}`;
  else if (site === 'park') fn = `f : ${c.t} → ${ansT}\nf a =\n    Task.yieldNow ⊤\n${ind(body('a'), 4)}`;
  else if (site === 'arm') fn = `f : ${c.t} → ${ansT}\nf a =\n    case List.length [ 1 ] of\n        0 →\n            ${fail}\n\n        _ →\n${ind(body('a'), 12)}`;
  else fn = `f : ${c.t} → ${ansT}\nf a =\n    inner b =\n${ind(body('b'), 8)}\n    inner a`;
  const showCell = op === 'err' ? 'String.fromInt (Ref.get c)' : `${c.show} (Ref.get c)`;
  const errArm = op === 'err' ? `Err ee →\n    [ ${c.show} ee ]` : wrap === 'maybe' ? 'Nothing →\n    [ "-" ]' : 'Err m →\n    [ m ]';
  const upd = op === 'err' ? 'Ref.update c λw → w + 1' : `Ref.update c λw → ${c.w('w')}`;
  let lines;
  if (use === 'read') lines = [`v = ${c.init}`, `case f v of\n    ${okc} c →\n        [ ${showCell} ]\n\n${ind(errArm, 4)}`];
  else if (use === 'argAfter') lines = [`v = ${c.init}`, `case f v of\n    ${okc} c →\n        ${upd}\n        [ ${c.show} v, ${showCell} ]\n\n${ind(errArm, 4)}`];
  else if (use === 'writeArg') lines = [`v = ${c.init}`, 'r = f v', `v2 = ${c.w('v')}`, `case r of\n    ${okc} c →\n        [ ${c.show} v2, ${showCell} ]\n\n${ind(errArm, 4)}`];
  else lines = [`v = ${c.init}`, `case f v of\n    ${okc} c →\n        b = Task.spawn λ⊤ → ${upd}\n        Task.yieldNow ⊤\n        s = ${c.show} v\n        Task.join b\n        [ s, ${showCell} ]\n\n${ind(errArm, 4)}`];
  return `-- try.${cname}.${wrap}.${op}.${site}.${use}: see bench/ownership-sweeps/cells.mjs.
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


showP : List Int × List Int → String
showP p = "\${ints p.0}/\${ints p.1}"


src : ⊤ → ${M} ${refT}
src ⊤ = ${OK} (${c.init})


wrap : ${c.t} → ${M} ${refT}
wrap a = ${OK} a


check : ${c.t} → Result ${refT} Int
check a = Err a


${fn}


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

// #2598: a closure that captured the cell writes its contents, then stores a list it makes in the cell
// and lets the list go on (kernel §13 item 11). A runner that runs it twice writes, in its second run,
// the list its first run stored, which the holder reads. Programs are
// `esc.<write>.<escape>.<runner>.<runs>.<twin>`: `write` the closure's write (`upd`, `Ref.update`;
// `mod`, `Ref.modify`); `escape` where the list goes besides the cell (`none`; `deferred`, a captured
// `Deferred`; `spawn`, a fiber the closure spawns and answers, which reads it after a sleep; `queue`, a
// captured `Queue`; `list`, a second cell that holds a list of lists; `record`, the closure's answer in a
// record; `answer`, the closure's answer; `cell2`, a second cell that the first run alone stores into;
// `cell2last`, a second cell that each run stores into, read after: it holds the last run's list);
// `runner` what runs the closure (`map`, `List.map`; `fold`, a `List.foldl` callback that calls it;
// `helper`, a user helper that calls its parameter; `scope`, a `Task.scope` body that calls it; `fibers`,
// a spawned fiber for each run, kernel §13 item 12; `direct`, the frame calls it); `runs` `twice` or
// `once`. A run once and the escapes `none` and `cell2last` are `dead`.
const ESC_WRITES = {
  upd: 'Ref.update r λxs → List.push xs 1',
  mod: '_ = Ref.modify r λxs → ( 1, List.push xs 1 )',
};
const ESC = {
  none: { body: [], ans: '⊤', show: 'ints (Ref.get r)' },
  deferred: { body: ['_ = Deferred.complete d l'], ans: '⊤', show: 'ints (Deferred.wait d)' },
  spawn: { body: [], ans: 'Task.spawn λ⊤ →\n    Io.sleep 5\n    ints l', show: 'String.join (List.map outs Task.join) " "' },
  queue: { body: ['_ = Queue.offer q l'], ans: '⊤', show: 'String.join (List.map (Queue.takeAll q) ints) " "' },
  list: { body: ['Ref.update acc λls → List.push ls l'], ans: '⊤', show: 'String.join (List.map (Ref.get acc) ints) " "' },
  record: { body: [], ans: '{ xs = l, n = 1 }', show: 'String.join (List.map outs λo → ints o.xs) " "' },
  answer: { body: [], ans: 'l', show: 'String.join (List.map outs ints) " "' },
  cell2: { body: ['k = Ref.get cnt', 'Ref.set cnt (k + 1)', 'if k == 0 then Ref.set r2 l'], ans: '⊤', show: 'ints (Ref.get r2)' },
  cell2last: { body: ['Ref.set r2 l'], ans: '⊤', show: 'ints (Ref.get r2)' },
};
const ESC_RUNNERS = {
  map: (n) => `outs = List.map ${n === 2 ? '[ ⊤, ⊤ ]' : '[ ⊤ ]'} g`,
  fold: (n) => `outs = List.foldl ${n === 2 ? '[ ⊤, ⊤ ]' : '[ ⊤ ]'} [] λu os → List.push os (g u)`,
  helper: (n) => `outs = ${n === 2 ? 'twice' : 'once'} g`,
  scope: (n) => `outs = Task.scope λs → ${n === 2 ? '[ g ⊤, g ⊤ ]' : '[ g ⊤ ]'}`,
  fibers: (n) => (n === 2 ? 'fa = Task.spawn λ⊤ → g ⊤\nfb = Task.spawn λ⊤ → g ⊤\nouts = [ Task.join fa, Task.join fb ]' : 'fa = Task.spawn λ⊤ → g ⊤\nouts = [ Task.join fa ]'),
  direct: (n) => `outs = ${n === 2 ? '[ g ⊤, g ⊤ ]' : '[ g ⊤ ]'}`,
};

function genEsc(write, escape, runner, n) {
  const e = ESC[escape];
  const g = [ESC_WRITES[write], 'l = [ 7 ]', 'Ref.set r l', ...e.body, e.ans].join('\n');
  const lines = [
    'r = Ref.make [ 0 ]',
    'd = Deferred.make ⊤',
    'q = Queue.unbounded ⊤',
    'acc = Ref.make []',
    'r2 = Ref.make [ 0 ]',
    'cnt = Ref.make 0',
    `g = λu →\n${ind(g, 4)}`,
    ESC_RUNNERS[runner](n),
    `[ ${e.show}, String.fromInt (List.length outs) ]`,
  ];
  return `-- esc.${write}.${escape}.${runner}: see bench/ownership-sweeps/cells.mjs.
import Deferred exposing (Deferred)
import Io
import Node exposing (Program)
import Queue exposing (Queue)
import Ref exposing (Ref)
import Task


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


twice : (⊤ → a) → List a
twice f = [ f ⊤, f ⊤ ]


once : (⊤ → a) → List a
once f = [ f ⊤ ]


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

// The same closure over a cell of two parts, which stores one list it made at both parts and lets it go
// nowhere else (`esc2.<shape>.<runner>.<runs>.<twin>`): `pair` (`( l, l )`), `record` (`{ a = l, b = l }`),
// `callee` (a helper answers `( l, l )`); or puts the first part's old list at the second too (`old`, `( a, a )`;
// `oldRecord`, `{ o | b = o.a }`), or the second part's at both (`otherOld`, `( b, b )`); in its first run only
// (a counter cell). Its next run pushes onto the first part, and the frame reads the second.
const ESC2 = {
  pair: { t: 'List Int × List Int', init: '( [ 0 ], [ 0 ] )', upd: 'λ( a, b ) → ( List.push a 1, b )', store: '( l, l )', second: (v) => `${v}.1` },
  record: { t: 'P', init: '{ a = [ 0 ], b = [ 0 ] }', upd: 'λp → { p | a = List.push p.a 1 }', store: '{ a = l, b = l }', second: (v) => `${v}.b` },
  callee: { t: 'List Int × List Int', init: '( [ 0 ], [ 0 ] )', upd: 'λ( a, b ) → ( List.push a 1, b )', store: 'dup ⊤', second: (v) => `${v}.1` },
  old: { t: 'List Int × List Int', init: '( [ 0 ], [ 0 ] )', upd: 'λ( a, b ) → ( List.push a 1, b )', line: 'Ref.update r λ( a, b ) → ( a, a )', second: (v) => `${v}.1` },
  oldRecord: { t: 'P', init: '{ a = [ 0 ], b = [ 0 ] }', upd: 'λp → { p | a = List.push p.a 1 }', line: 'Ref.update r λo → { o | b = o.a }', second: (v) => `${v}.b` },
  otherOld: { t: 'List Int × List Int', init: '( [ 0 ], [ 0 ] )', upd: 'λ( a, b ) → ( List.push a 1, b )', line: 'Ref.update r λ( a, b ) → ( b, b )', second: (v) => `${v}.1` },
};

function genEsc2(shape, runner, n) {
  const s = ESC2[shape];
  const store = s.line ?? (shape === 'callee' ? `Ref.set r (${s.store})` : `l = [ 7 ]\nRef.set r (${s.store})`);
  const g = [`Ref.update r ${s.upd}`, 'k = Ref.get cnt', 'Ref.set cnt (k + 1)', `if k == 0 then\n${ind(store, 4)}`, '⊤'].join('\n');
  const lines = [
    `r = Ref.make (${s.init})`,
    'cnt = Ref.make 0',
    `g = λu →\n${ind(g, 4)}`,
    ESC_RUNNERS[runner](n),
    `v = Ref.get r`,
    `[ ints (${s.second('v')}), String.fromInt (List.length outs) ]`,
  ];
  return `-- esc2.${shape}.${runner}: see bench/ownership-sweeps/cells.mjs.
import Io
import Node exposing (Program)
import Ref exposing (Ref)
import Task


type alias P =
    { a : List Int, b : List Int }


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


dup : ⊤ → List Int × List Int
dup ⊤ =
    l = [ 7 ]
    ( l, l )


twice : (⊤ → a) → List a
twice f = [ f ⊤, f ⊤ ]


once : (⊤ → a) → List a
once f = [ f ⊤ ]


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

// #2600: a body leaves in the cell, across a park, a value the caller does not name there, and a writer
// fiber the caller spawned writes it in place while the body is parked (kernel §13 item 12). Programs are
// `park.<stored>.<park>.<runner>.<writer>.<twin>`: `stored` what the body leaves in the cell: a value of
// outside the frame (`topList`, a top-level list; `topRecord`, a top-level record; `topDict`, a top-level
// dictionary; `topCtor`, a list inside a top-level constructor; `nested`, a new cell holding a top-level
// list, in a cell of cells; `nestedSet`, a top-level list stored in the inner cell), or the cell's own old contents at another location (`swap`, two parts of a
// tuple swapped; `swapRec`, two fields of a record swapped; `copy`, the second part copied to the first;
// `nestedSwap`, two cells in a tuple swapped), then a value of its own again after the park; `park` the
// switch point (`yield`, `Task.yieldNow`; `sleep`, `Io.sleep`; `deferred`, `Deferred.wait` of a deferred
// the writer completes; `queue`, `Queue.take` of a queue the writer offers to; `helper`, a function that
// parks); `runner` what runs the body (`direct`, a helper over the cell; `map`, a closure run by
// `List.map`; `fold`, by `List.foldl`; `scope`, by `Task.scope`); `writer` `fiber` (a spawned fiber writes
// the contents in place, joined after) or `self` (the frame writes them after the body); the twin is
// `live` where the frame reads the outside value or the old part after, `dead` otherwise. `copy` reads
// the cell after too, so its dead twin can differ as well.
const PARK_STORED = {
  topList: { t: 'List Int', init: '[ 0 ]', store: 'Ref.set r big', restore: 'Ref.set r [ 0 ]', w: 'Ref.update r λl → List.push l 1', old: 'ints big', show: 'ints (Ref.get r)' },
  topRecord: { t: 'R', init: '{ items = [ 0 ], n = 0 }', store: 'Ref.set r topR', restore: 'Ref.set r { items = [ 0 ], n = 0 }', w: 'Ref.update r λv → { v | n = v.n + 1 }', old: 'String.fromInt topR.n', show: 'String.fromInt (Ref.get r).n' },
  topDict: { t: 'Dict Int (List Int)', init: 'Dict.fromList [ ( 1, [ 1 ] ) ]', store: 'Ref.set r topD', restore: 'Ref.set r (Dict.fromList [ ( 1, [ 1 ] ) ])', w: 'Ref.update r λdd → Dict.insert dd 3 [ 30 ]', old: 'String.fromInt (Dict.size topD)', show: 'String.fromInt (Dict.size (Ref.get r))' },
  topCtor: { t: 'List Int', init: '[ 0 ]', store: 'Ref.set r (unbox boxed)', restore: 'Ref.set r [ 0 ]', w: 'Ref.update r λl → List.push l 1', old: 'ints (unbox boxed)', show: 'ints (Ref.get r)' },
  nested: { t: 'Ref (List Int)', init: 'Ref.make [ 0 ]', store: 'Ref.set r (Ref.make big)', restore: 'Ref.set r (Ref.make [ 0 ])', w: 'Ref.update (Ref.get r) λl → List.push l 1', old: 'ints big', show: 'ints (Ref.get (Ref.get r))' },
  nestedSet: { t: 'Ref (List Int)', init: 'Ref.make [ 0 ]', store: 'Ref.set (Ref.get r) big', restore: 'Ref.set (Ref.get r) [ 0 ]', w: 'Ref.update (Ref.get r) λl → List.push l 1', old: 'ints big', show: 'ints (Ref.get (Ref.get r))' },
  swap: { t: 'List Int × List Int', init: '( [ 1 ], [ 2 ] )', pre: '( _, bb ) = Ref.get r', store: 'Ref.update r λ( x, y ) → ( y, x )', restore: 'Ref.update r λ( x, y ) → ( y, x )', w: 'Ref.update r λ( x, y ) → ( List.push x 9, y )', old: 'ints bb', show: 'showP (Ref.get r)' },
  swapRec: { t: 'P', init: '{ a = [ 1 ], b = [ 2 ] }', pre: 'bb = (Ref.get r).b', store: 'Ref.update r λo → { a = o.b, b = o.a }', restore: 'Ref.update r λo → { a = o.b, b = o.a }', w: 'Ref.update r λo → { o | a = List.push o.a 9 }', old: 'ints bb', show: 'showRec (Ref.get r)' },
  copy: { t: 'List Int × List Int', init: '( [ 1 ], [ 2 ] )', pre: '( _, bb ) = Ref.get r', store: 'Ref.update r λ( x, y ) → ( y, y )', restore: 'Ref.update r λ( x, y ) → ( [ 1 ], y )', w: 'Ref.update r λ( x, y ) → ( List.push x 9, y )', old: 'ints bb', show: 'showP (Ref.get r)' },
  nestedSwap: { t: 'Ref (List Int) × Ref (List Int)', init: '( Ref.make [ 1 ], Ref.make [ 2 ] )', pre: '( _, ib ) = Ref.get r\nbb = Ref.get ib', store: 'Ref.update r λ( x, y ) → ( y, x )', restore: 'Ref.update r λ( x, y ) → ( y, x )', w: 'Ref.update (Ref.get r).0 λl → List.push l 9', old: 'ints bb', show: 'showRefs (Ref.get r)' },
};
const PARK_POINTS = {
  yield: { line: 'Task.yieldNow ⊤', signal: [], ready: [] },
  sleep: { line: 'Io.sleep 1', signal: [], ready: [] },
  deferred: { line: 'Deferred.wait d', signal: ['_ = Deferred.complete d ⊤'], ready: ['_ = Deferred.complete d ⊤'] },
  queue: { line: '_ = Queue.take q', signal: ['_ = Queue.offer q 1'], ready: ['_ = Queue.offer q 1'] },
  helper: { line: 'parkHelper ⊤', signal: [], ready: [] },
};

function genPark(stored, park, runner, writer, live) {
  const s = PARK_STORED[stored];
  const p = PARK_POINTS[park];
  const body = [s.store, p.line, s.restore].join('\n');
  const helper = runner === 'direct' ? `\n\n\nbody : Ref (${s.t}), Deferred ⊤, Queue Int → ⊤\nbody r d q =\n${ind(body, 4)}` : '';
  const run = {
    direct: 'body r d q',
    map: `_ = List.map [ ⊤ ] λ⊤ →\n${ind(body, 4)}`,
    fold: `_ = List.foldl [ ⊤ ] ⊤ λu acc →\n${ind(body, 4)}`,
    scope: `_ = Task.scope λsc →\n${ind(body, 4)}`,
  }[runner];
  const lines = [
    `r = Ref.make (${s.init})`,
    'd = Deferred.make ⊤',
    'q = Queue.unbounded ⊤',
    ...(s.pre ? [s.pre] : []),
    ...(writer === 'fiber' ? [`a = Task.spawn λ⊤ →\n${ind([s.w, ...p.signal, '⊤'].join('\n'), 4)}`] : p.ready),
    run,
    ...(writer === 'fiber' ? ['Task.join a'] : [s.w]),
    `[ ${live ? `${s.old}, ` : ''}${s.show} ]`,
  ];
  return `-- park.${stored}.${park}.${runner}.${writer}: see bench/ownership-sweeps/cells.mjs.
import Deferred exposing (Deferred)
import Dict exposing (Dict)
import Io
import Node exposing (Program)
import Queue exposing (Queue)
import Ref exposing (Ref)
import Task


type alias R =
    { items : List Int, n : Int }


type alias P =
    { a : List Int, b : List Int }


type Box
    = Box (List Int)


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


showP : List Int × List Int → String
showP ( x, y ) = ints x ++ " " ++ ints y


showRec : P → String
showRec o = ints o.a ++ " " ++ ints o.b


showRefs : Ref (List Int) × Ref (List Int) → String
showRefs ( x, y ) = ints (Ref.get x) ++ " " ++ ints (Ref.get y)


unbox : Box → List Int
unbox b =
    case b of
        Box l → l


big : List Int
big = [ 100 ]


topR : R
topR = { items = [ 100 ], n = 0 }


topD : Dict Int (List Int)
topD = Dict.fromList [ ( 1, [ 100 ] ) ]


boxed : Box
boxed = Box [ 100 ]


parkHelper : ⊤ → ⊤
parkHelper ⊤ = Task.yieldNow ⊤${helper}


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

// #2604: a fiber that only reads a cell (a reader, kernel §13 item 12) still reads it after the frame
// that spawned it returns, and a holder then writes in place what it reads. Programs are
// `reader.<out>.<read>.<twin>`: `out` how the contents leave the frame `mk` that made the cell and
// spawned the reader (`answered`, the handle answered; `loan`, a value `Ref.get` answered; `record`,
// `list`, `maybe`, `dict`, `cell`, the handle in a record, a list, a `Just`, a dictionary, another
// cell; `loanRecord`, a loan in a record; `loanCell`, a loan as another cell's contents; `stored`, a
// loan stored in a parameter's cell; `storedCap`, in a cell a closure captured; `deferred`, `queue`, a
// loan handed through a `Deferred` or a `Queue`; `tryErr`, a loan answered by an early `?`; `nested`, a
// helper that answers `mk`'s answer; `helperSpawn`, the reader spawned by a helper handed the handle;
// `scope`, `mk`'s body in `Task.scope`; `race`, `par`, `forEach`, the read inside `Task.race`,
// `Task.par`, `Task.forEach` in the spawned fiber; `alias`, a writer fiber of a second cell that holds
// the first cell's contents, spawned after the reader, or before it in `aliasFirst`; `param`, the cell
// made with a list `mk` is handed, which the caller writes; `second`, the second cell of the `two`
// reader answered; `cellUpd`, the caller updates the answered handle, which the reader reads through;
// `loanFirst` and `storedFirst`, `loan` and `stored` with the loan taken before the spawn; `readHelper`, the
// reader reads through a helper handed the cell, the handle answered; `arm`, the reader spawned in an arm
// of an `if`, a loan answered; `setLoan`, `mk` stores a new list after the spawn and answers a loan of it;
// `storedHandle`, the handle stored in a parameter's cell of cells; `getter`, a closure that answers a loan
// answered beside the fiber; `mapped`, the cell made and the reader spawned in a callback of `List.map`
// that answers a loan;
// `joined`, `mk` joins the reader before it answers a loan, which the caller writes in place: these two
// dead only, the write in place); `read` the reader (`plain`, `park` after `Task.yieldNow`, `sleep` after
// `Io.sleep`, `two` two cells, the answered one first); the twin is `live` where the caller's write is
// in place, `dead` where it writes a `List.copy`.
const READER_OUTS = ['answered', 'loan', 'record', 'list', 'maybe', 'dict', 'cell', 'loanRecord', 'loanCell', 'stored', 'storedCap', 'deferred', 'queue', 'tryErr', 'nested', 'helperSpawn', 'scope', 'race', 'par', 'forEach', 'alias', 'aliasFirst', 'param', 'second', 'loanFirst', 'storedFirst', 'readHelper', 'arm', 'setLoan', 'storedHandle', 'getter', 'mapped', 'cellUpd', 'joined'];
const READER_READS = {
  plain: 'List.length (Ref.get r)',
  park: 'Task.yieldNow ⊤\nList.length (Ref.get r)',
  sleep: 'Io.sleep 1\nList.length (Ref.get r)',
  two: 'List.length (Ref.get r) + List.length (Ref.get r2)',
};

function genReader(outKind, read, live) {
  const w = (x) => (live ? `List.push ${x} 9` : `List.push (List.copy ${x}) 9`);
  const rd = READER_READS[read];
  const body = {
    race: `Task.race\n    (λ⊤ →\n${ind(rd, 8)}\n    )\n    λ⊤ →\n        Io.sleep 50\n        0`,
    par: `( x, y ) = Task.par\n    (λ⊤ →\n${ind(rd, 8)}\n    )\n    λ⊤ → 0\nx + y`,
    forEach: `List.length (Task.forEach [ 1 ] 1 λk →\n${ind(rd, 4)}\n)`,
  }[outKind] ?? rd;
  const spawn = outKind === 'helperSpawn'
    ? 'a = spawnR r r2'
    : outKind === 'readHelper'
      ? 'a = Task.spawn λ⊤ → readIt r r2'
      : outKind === 'arm'
        ? `a =\n    if List.length (Ref.get r2) > 0 then\n        Task.spawn λ⊤ →\n${ind(body, 12)}\n\n    else\n        Task.spawn λ⊤ → 0`
        : `a = Task.spawn λ⊤ →\n${ind(body, 4)}`;
  const make = ['r = Ref.make [ 1 ]', 'r2 = Ref.make [ 5 ]', spawn];
  let mk;
  let probe;
  const tail = (ys) => `"\${String.fromInt (Task.join a)} \${ints ${ys}}"`;
  switch (outKind) {
    case 'answered':
    case 'nested':
    case 'helperSpawn':
      mk = `mk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( r, a )'].join('\n'), 4)}`;
      if (outKind === 'nested') mk += `\n\n\nmk2 : ⊤ → Ref (List Int) × Task.Fiber Int\nmk2 ⊤ =\n    ( r, a ) = mk ⊤\n    ( r, a )`;
      probe = [`( r, a ) = ${outKind === 'nested' ? 'mk2' : 'mk'} ⊤`, `ys = ${w('(Ref.get r)')}`, tail('ys')];
      break;
    case 'loanFirst':
      mk = `mk : ⊤ → List Int × Task.Fiber Int\nmk ⊤ =\n${ind([...make.slice(0, 2), 'l = Ref.get r', make[2], '( l, a )'].join('\n'), 4)}`;
      probe = ['( l, a ) = mk ⊤', `ys = ${w('l')}`, tail('ys')];
      break;
    case 'storedFirst':
      mk = `mk : Ref (List Int) → Task.Fiber Int\nmk out =\n${ind([...make.slice(0, 2), 'Ref.set out (Ref.get r)', make[2], 'a'].join('\n'), 4)}`;
      probe = ['out = Ref.make [ 0 ]', 'a = mk out', `Ref.update out λl → ${w('l')}`, tail('(Ref.get out)')];
      break;
    case 'readHelper':
      mk = `readIt : Ref (List Int), Ref (List Int) → Int\nreadIt r r2 =\n${ind(rd, 4)}\n\n\nmk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( r, a )'].join('\n'), 4)}`;
      probe = ['( r, a ) = mk ⊤', `ys = ${w('(Ref.get r)')}`, tail('ys')];
      break;
    case 'arm':
      mk = `mk : ⊤ → List Int × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( Ref.get r, a )'].join('\n'), 4)}`;
      probe = ['( l, a ) = mk ⊤', `ys = ${w('l')}`, tail('ys')];
      break;
    case 'setLoan':
      mk = `mk : ⊤ → List Int × Task.Fiber Int\nmk ⊤ =\n${ind([...make, 'Ref.set r [ 7 ]', '( Ref.get r, a )'].join('\n'), 4)}`;
      probe = ['( l, a ) = mk ⊤', `ys = ${w('l')}`, tail('ys')];
      break;
    case 'storedHandle':
      mk = `mk : Ref (Ref (List Int)) → Task.Fiber Int\nmk out =\n${ind([...make, 'Ref.set out r', 'a'].join('\n'), 4)}`;
      probe = ['out = Ref.make (Ref.make [ 0 ])', 'a = mk out', `ys = ${w('(Ref.get (Ref.get out))')}`, tail('ys')];
      break;
    case 'getter':
      mk = `mk : ⊤ → (⊤ → List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( λ⊤ → Ref.get r, a )'].join('\n'), 4)}`;
      probe = ['( g, a ) = mk ⊤', `ys = ${w('(g ⊤)')}`, tail('ys')];
      break;
    case 'mapped':
      mk = '';
      probe = [`ps =\n    List.map [ 1 ] λk →\n${ind([...make, '( Ref.get r, a )'].join('\n'), 8)}`, `case ps of\n    [ ( l, a ) ] →\n        ys = ${w('l')}\n        ${tail('ys')}\n\n    _ → ""`];
      break;
    case 'second':
      mk = `mk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( r2, a )'].join('\n'), 4)}`;
      probe = ['( r, a ) = mk ⊤', `ys = ${w('(Ref.get r)')}`, tail('ys')];
      break;
    case 'param':
      mk = `mk : List Int → Task.Fiber Int\nmk xs =\n${ind(['r = Ref.make xs', ...make.slice(1), 'a'].join('\n'), 4)}`;
      probe = ['xs = [ 1 ]', 'a = mk xs', `ys = ${w('xs')}`, tail('ys')];
      break;
    case 'joined':
      mk = `mk : ⊤ → List Int × Int\nmk ⊤ =\n${ind([...make, 'n = Task.join a', '( Ref.get r, n )'].join('\n'), 4)}`;
      probe = ['( l, n ) = mk ⊤', 'ys = List.push l 9', '"${String.fromInt n} ${ints ys}"'];
      break;
    case 'cellUpd':
      mk = `mk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( r, a )'].join('\n'), 4)}`;
      probe = ['( r, a ) = mk ⊤', `Ref.update r λl → ${w('l')}`, tail('(Ref.get r)')];
      break;
    case 'loan':
      mk = `mk : ⊤ → List Int × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( Ref.get r, a )'].join('\n'), 4)}`;
      probe = ['( l, a ) = mk ⊤', `ys = ${w('l')}`, tail('ys')];
      break;
    case 'record':
      mk = `mk : ⊤ → H\nmk ⊤ =\n${ind([...make, '{ h = r, f = a }'].join('\n'), 4)}`;
      probe = ['x = mk ⊤', 'a = x.f', `ys = ${w('(Ref.get x.h)')}`, tail('ys')];
      break;
    case 'loanRecord':
      mk = `mk : ⊤ → L\nmk ⊤ =\n${ind([...make, '{ l = Ref.get r, f = a }'].join('\n'), 4)}`;
      probe = ['x = mk ⊤', 'a = x.f', `ys = ${w('x.l')}`, tail('ys')];
      break;
    case 'list':
      mk = `mk : ⊤ → List (Ref (List Int)) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( [ r ], a )'].join('\n'), 4)}`;
      probe = ['( hs, a ) = mk ⊤', `ys =\n    case hs of\n        [ h ] → ${w('(Ref.get h)')}\n        _ → []`, tail('ys')];
      break;
    case 'maybe':
      mk = `mk : ⊤ → Maybe (Ref (List Int)) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( Just r, a )'].join('\n'), 4)}`;
      probe = ['( m, a ) = mk ⊤', `ys =\n    case m of\n        Just h → ${w('(Ref.get h)')}\n        Nothing → []`, tail('ys')];
      break;
    case 'dict':
      mk = `mk : ⊤ → Dict Int (Ref (List Int)) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( Dict.fromList [ ( 1, r ) ], a )'].join('\n'), 4)}`;
      probe = ['( d, a ) = mk ⊤', `ys =\n    case Dict.get d 1 of\n        Just h → ${w('(Ref.get h)')}\n        Nothing → []`, tail('ys')];
      break;
    case 'cell':
      mk = `mk : ⊤ → Ref (Ref (List Int)) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( Ref.make r, a )'].join('\n'), 4)}`;
      probe = ['( c, a ) = mk ⊤', `ys = ${w('(Ref.get (Ref.get c))')}`, tail('ys')];
      break;
    case 'loanCell':
      mk = `mk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( Ref.make (Ref.get r), a )'].join('\n'), 4)}`;
      probe = ['( c, a ) = mk ⊤', `Ref.update c λl → ${w('l')}`, tail('(Ref.get c)')];
      break;
    case 'stored':
      mk = `mk : Ref (List Int) → Task.Fiber Int\nmk out =\n${ind([...make, 'Ref.set out (Ref.get r)', 'a'].join('\n'), 4)}`;
      probe = ['out = Ref.make [ 0 ]', 'a = mk out', `Ref.update out λl → ${w('l')}`, tail('(Ref.get out)')];
      break;
    case 'storedCap':
      mk = '';
      probe = ['out = Ref.make [ 0 ]', `fill = λ⊤ →\n${ind([...make, 'Ref.set out (Ref.get r)', 'a'].join('\n'), 4)}`, 'fa = fill ⊤', `Ref.update out λl → ${w('l')}`, '"${String.fromInt (Task.join fa)} ${ints (Ref.get out)}"'];
      break;
    case 'deferred':
      mk = `mk : Deferred (List Int) → Task.Fiber Int\nmk d =\n${ind([...make, '_ = Deferred.complete d (Ref.get r)', 'a'].join('\n'), 4)}`;
      probe = ['d = Deferred.make ⊤', 'a = mk d', `ys = ${w('(Deferred.wait d)')}`, tail('ys')];
      break;
    case 'queue':
      mk = `mk : Queue (List Int) → Task.Fiber Int\nmk q =\n${ind([...make, '_ = Queue.offer q (Ref.get r)', 'a'].join('\n'), 4)}`;
      probe = ['q = Queue.unbounded ⊤', 'a = mk q', `ys =\n    case Queue.take q of\n        Just l → ${w('l')}\n        Nothing → []`, tail('ys')];
      break;
    case 'tryErr':
      mk = `mk : Bool → Result (List Int × Task.Fiber Int) Int\nmk b =\n${ind([...make, '_ = (if b then Err ( Ref.get r, a ) else Ok 0) ?', 'Ok (Task.join a)'].join('\n'), 4)}`;
      probe = [`case mk True of\n    Err ( l, a ) →\n        ys = ${w('l')}\n        ${tail('ys')}\n\n    Ok _ → ""`];
      break;
    case 'scope':
      mk = `mk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n    Task.scope λsc →\n${ind([...make, '( r, a )'].join('\n'), 8)}`;
      probe = ['( r, a ) = mk ⊤', `ys = ${w('(Ref.get r)')}`, tail('ys')];
      break;
    case 'race':
    case 'par':
    case 'forEach':
      mk = `mk : ⊤ → Ref (List Int) × Task.Fiber Int\nmk ⊤ =\n${ind([...make, '( r, a )'].join('\n'), 4)}`;
      probe = ['( r, a ) = mk ⊤', `ys = ${w('(Ref.get r)')}`, tail('ys')];
      break;
    case 'alias':
    case 'aliasFirst': {
      const sw = ['s = Ref.make (Ref.get r)', `w = Task.spawn λ⊤ → Ref.update s λl → ${w('l')}`];
      const lines = outKind === 'alias' ? [...make, ...sw] : [...make.slice(0, 2), ...sw, make[2]];
      mk = `mk : ⊤ → Task.Fiber Int × Task.Fiber ⊤\nmk ⊤ =\n${ind([...lines, '( a, w )'].join('\n'), 4)}`;
      probe = ['( a, w ) = mk ⊤', 'Task.join w', '"${String.fromInt (Task.join a)}"'];
      break;
    }
    default:
      throw new Error(outKind);
  }
  return `-- reader.${outKind}.${read}: see bench/ownership-sweeps/cells.mjs.
import Deferred exposing (Deferred)
import Dict exposing (Dict)
import Io
import List
import Node exposing (Program)
import Queue exposing (Queue)
import Ref exposing (Ref)
import String
import Task


type alias H =
    { h : Ref (List Int), f : Task.Fiber Int }


type alias L =
    { l : List Int, f : Task.Fiber Int }


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


spawnR : Ref (List Int), Ref (List Int) → Task.Fiber Int
spawnR r r2 =
    Task.spawn λ⊤ →
${ind(rd, 8)}
${mk ? `\n\n${mk}\n` : ''}

probe : ⊤ → String
probe ⊤ =
${ind(probe.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines [ probe ⊤ ]
`;
}

// #2604 and #2605: program code that reads a cell between the in-place write of `Ref.update`'s (or
// `Ref.modify`'s) function and the store-back. `marked.<log>.<at>.<twin>`: a sink `Log.setSink` was
// handed reads the cell, and the function logs after its write (`log`: `info`, `span`, a `helper` that
// logs); `at` where the update runs (`frame`, `modify`, a `closure` called directly, a `fold`
// callback). `defect.<hook>.<at>.<twin>`: the function throws after its write (a stack overflow), and
// code a defect runs reads the cell (`hook`: `onDefect`, a `wrapper` and a `wrapper2` over it, a
// `field` of a record handed to it; the teardown's cleanups `bracket`'s release, `onExit`, `defer`, each
// over a helper that updates and throws, `frame` and `live` only); `at`: `frame`, `modify`, `fiber` (a
// spawned fiber's update, joined). The twin is `live` where the write is in place, `dead` where the
// function writes a `List.copy` (its run still throws).
const MARK_LOGS = {
  info: 'Log.info "mid"',
  span: 'Log.span "mid" λ⊤ → ⊤',
  helper: 'say ⊤',
};
const MARK_ATS = ['frame', 'modify', 'closure', 'fold'];
const DEFECT_HOOKS = ['onDefect', 'wrapper', 'wrapper2', 'field', 'bracket', 'onExit', 'defer'];
const DEFECT_INSTALLED = ['onDefect', 'wrapper', 'wrapper2', 'field'];
const DEFECT_ATS = ['frame', 'modify', 'fiber'];

// The update at `at`, whose function writes and then runs `body`, then `last` (its answer, or the
// answer's second part for `modify`).
function updateAt(at, body, live, last = '') {
  const push = live ? 'List.push l 5' : 'List.push (List.copy l) 5';
  const fn = ['λl →', `    l2 = ${push}`, ind(body, 4), `    ${last || 'l2'}`].join('\n');
  const fnM = ['λl →', `    l2 = ${push}`, ind(body, 4), `    ( 0, ${last || 'l2'} )`].join('\n');
  return {
    frame: `Ref.update r ${fn}`,
    modify: `_ = Ref.modify r ${fnM}`,
    closure: `bump = λ⊤ → Ref.update r ${fn}\nbump ⊤`,
    fold: `_ = List.foldl [ 1 ] ⊤ λk acc → Ref.update r ${fn}`,
    fiber: `w = Task.spawn λ⊤ → Ref.update r ${fn}\nTask.join w`,
  }[at];
}

const MD_HEAD = `import Io
import List
import Log
import Node exposing (Program)
import Ref exposing (Ref)
import String
import Task


type alias Hooks =
    { h : ⊤ → ⊤ }


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


say : ⊤ → ⊤
say ⊤ = Log.info "mid"


deep : Int → Int
deep n = if n < 0 then 0 else 1 + deep (n + 1)


install : (⊤ → ⊤) → ⊤
install f = Task.onDefect f


install2 : (⊤ → ⊤) → ⊤
install2 f = install f


boom : Ref (List Int) → ⊤
boom q =
    Ref.update q λl →
        l2 = List.push l 5
        if deep 0 > 0 then l2 else l2
`;

const mdMain = (name, lines) => `-- ${name}: see bench/ownership-sweeps/cells.mjs.
${MD_HEAD}

go : ⊤ → String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines [ go ⊤ ]
`;

function genMarked(log, at, live) {
  const lines = ['r = Ref.make [ 1, 2 ]', 'Log.setSink λent → Debug.log "sink ${ints (Ref.get r)}" ⊤', updateAt(at, MARK_LOGS[log], live), 'ints (Ref.get r)'];
  return mdMain(`marked.${log}.${at}`, lines);
}

function genDefect(hook, at, live) {
  const read = 'Log.info "hook ${ints (Ref.get r)}"';
  const install = {
    onDefect: [`Task.onDefect λ⊤ → ${read}`],
    wrapper: [`install λ⊤ → ${read}`],
    wrapper2: [`install2 λ⊤ → ${read}`],
    field: [`hs = { h = λ⊤ → ${read} }`, 'Task.onDefect hs.h'],
  }[hook];
  const cleanup = {
    bracket: 'Task.bracket (λ⊤ → r) (λq _ → Log.info "cleanup ${ints (Ref.get q)}") λq → boom q',
    onExit: 'Task.onExit (λ⊤ → boom r) λ_ → Log.info "exit ${ints (Ref.get r)}"',
    defer: 'Task.scope λsc →\n    Task.defer sc λ_ → Log.info "defer ${ints (Ref.get r)}"\n    boom r',
  }[hook];
  const lines = install
    ? ['r = Ref.make [ 1, 2 ]', ...install, updateAt(at, 'n = deep 0', live, 'if n > 0 then l2 else l2'), 'ints (Ref.get r)']
    : ['r = Ref.make [ 1, 2 ]', cleanup, 'ints (Ref.get r)'];
  return mdMain(`defect.${hook}.${at}`, lines);
}

// `reach.<shape>.<at>.<twin>` (#2609): code a defect runs reaches the reader by a way other than its
// own parameter. `shape`: a helper that wraps its parameter in a closure for `Task.onDefect` (`wrapped`),
// a second helper over it (`wrapped2`), a local closure (`nested`), a record (`record`), a list
// (`list`), a cell (`cell`, `cellLater`: stored after the hook is installed), a `Dict` (`dict`), a closure over it
// in a record (`box`), a function applied to it with `_` (`partial`), a record the caller builds (`callerRecord`), and
// `Task.onDefect` handed on as a value to a parameter (`handed`), in a list (`folded`), in a record
// (`field`), an `if` with a lambda (`join`), a cell (`cellFn`) or a list pattern (`listPattern`), and
// `Log.setSink` in a record (`sinkField`; blind round BT); `at` as in
// `defect`. The function throws after its write; the twin is `live` where the write is in place.
const REACH = {
  wrapped: ['inst : (⊤ → ⊤) → ⊤\ninst f = Task.onDefect λ⊤ → f ⊤', (rd) => `inst ${rd}`],
  wrapped2: ['inst0 : (⊤ → ⊤) → ⊤\ninst0 g = Task.onDefect λ⊤ → g ⊤\n\n\ninst : (⊤ → ⊤) → ⊤\ninst f = inst0 λ⊤ → f ⊤', (rd) => `inst ${rd}`],
  nested: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    g = λ⊤ → f ⊤\n    Task.onDefect λ⊤ → g ⊤', (rd) => `inst ${rd}`],
  record: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    b = { h = f }\n    Task.onDefect λ⊤ → b.h ⊤', (rd) => `inst ${rd}`],
  list: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    fs = [ f ]\n    Task.onDefect λ⊤ → List.foldl fs ⊤ λg _ → g ⊤', (rd) => `inst ${rd}`],
  cell: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    c = Ref.make f\n    Task.onDefect λ⊤ → (Ref.get c) ⊤', (rd) => `inst ${rd}`],
  cellLater: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    c = Ref.make λ⊤ → ⊤\n    Task.onDefect λ⊤ → (Ref.get c) ⊤\n    Ref.set c f', (rd) => `inst ${rd}`],
  dict: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    d = Dict.singleton 1 f\n    Task.onDefect λ⊤ →\n        case Dict.get d 1 of\n            Just g →\n                g ⊤\n            Nothing →\n                ⊤', (rd) => `inst ${rd}`],
  box: ['inst : (⊤ → ⊤) → ⊤\ninst f =\n    b = { h = λ⊤ → f ⊤ }\n    Task.onDefect λ⊤ → b.h ⊤', (rd) => `inst ${rd}`],
  partial: ['call : (⊤ → ⊤), ⊤ → ⊤\ncall f x = f x\n\n\ninst : (⊤ → ⊤) → ⊤\ninst f = Task.onDefect (call f _)', (rd) => `inst ${rd}`],
  callerRecord: ['inst : Hooks → ⊤\ninst b = Task.onDefect λ⊤ → b.h ⊤', (rd) => `inst { h = ${rd} }`],
  handed: ['reg : ((⊤ → ⊤) → ⊤), (⊤ → ⊤) → ⊤\nreg hr f = hr f', (rd) => `reg Task.onDefect ${rd}`],
  field: ['type alias Cfg =\n    { install : (⊤ → ⊤) → ⊤ }', (rd) => `cfg : Cfg\ncfg = { install = Task.onDefect }\ncfg.install ${rd}`],
  join: ['', (rd) => `reg = if List.length (Ref.get r) > 0 then Task.onDefect else λ_ → ⊤\nreg ${rd}`],
  cellFn: ['', (rd) => `fr = Ref.make Task.onDefect\n(Ref.get fr) ${rd}`],
  listPattern: ['', (rd) => `case [ Task.onDefect ] of\n    [ g, …_ ] →\n        g ${rd}\n    _ →\n        ⊤`],
  sinkField: ['type alias Sinks =\n    { sink : (Log.Entry → ⊤) → ⊤ }', () => 'cfg : Sinks\ncfg = { sink = Log.setSink }\ncfg.sink λ_ → Debug.log "sink ${ints (Ref.get r)}" ⊤\nTask.onDefect λ⊤ → Log.info "defect"'],
  folded: ['inst : (⊤ → ⊤) → ⊤\ninst f = List.foldl [ Task.onDefect ] ⊤ λh _ → h f', (rd) => `inst ${rd}`],
};

function genReach(shape, at, live) {
  const [defs, inst] = REACH[shape];
  const lines = ['r = Ref.make [ 1, 2 ]', inst('λ⊤ → Log.info "hook ${ints (Ref.get r)}"'), updateAt(at, 'n = deep 0', live, 'if n > 0 then l2 else l2'), 'ints (Ref.get r)'];
  return mdMain(`reach.${shape}.${at}`, lines).replace('import Io\n', 'import Dict\nimport Io\n').replace('\n\ngo : ⊤ → String', `\n\n${defs}\n\n\ngo : ⊤ → String`);
}

// `runon.<other>.<writer>.<twin>` (#2613): pages, on a copy of `browser-inline` with no `"lists"` key
// (written to `<out>/_platform`, so the plain build is the oracle), where code that runs on after a
// throw reads the cell an update stopped in the middle of. `other`: a fiber that sleeps inside
// `Task.uninterruptible` and then reads (`maskRead`) or writes and reads (`maskWrite`), inside
// `uninterruptibleMask` (`maskMaskRead`) or through a helper over `uninterruptible` (`maskHelperRead`),
// with the update that throws in the frame (`frame`), a closure (`closure`), a helper (`helper`) or under
// `Task.withScheduler` (`sched`); or the frame, which reads after a spawned fiber's update throws under
// `Task.withScheduler`, which stops only that scheduler (`frameRead`, with `spawnSched`, `spawnSchedHelper`).
// Open (#2613): v3 accepts the live twins today, and they trap.
// The twin is `live` where the write is in place.
const RUNON_OTHERS = {
  maskRead: ['_ = Task.spawn λ⊤ →', '    Task.uninterruptible λ⊤ →', '        Task.sleep (Duration.millis 5)', '        Log.info (ints (Ref.get r))'],
  maskWrite: ['_ = Task.spawn λ⊤ →', '    Task.uninterruptible λ⊤ →', '        Task.sleep (Duration.millis 5)', '        Ref.update r λl → List.push l 7', '        Log.info (ints (Ref.get r))'],
  maskMaskRead: ['_ = Task.spawn λ⊤ →', '    Task.uninterruptibleMask λ_ →', '        Task.sleep (Duration.millis 5)', '        Log.info (ints (Ref.get r))'],
  maskHelperRead: ['_ = Task.spawn λ⊤ →', '    masked λ⊤ →', '        Task.sleep (Duration.millis 5)', '        Log.info (ints (Ref.get r))'],
};
const RUNON_WRITERS = {
  frame: (push) => ['Task.sleep (Duration.millis 1)', 'Ref.update r λl →', `    l2 = ${push}`, '    n = deep 0', '    if n > 0 then l2 else l2'],
  closure: (push) => ['Task.sleep (Duration.millis 1)', 'bumpIt = λ⊤ →', '    Ref.update r λl →', `        l2 = ${push}`, '        n = deep 0', '        if n > 0 then l2 else l2', 'bumpIt ⊤'],
  helper: () => ['Task.sleep (Duration.millis 1)', 'bump r'],
  sched: (push) => ['Task.withScheduler sc λ⊤ →', '    Task.sleep (Duration.millis 1)', '    Ref.update r λl →', `        l2 = ${push}`, '        n = deep 0', '        if n > 0 then l2 else l2'],
  spawnSched: () => ['_ = Task.spawn λ⊤ → Task.withScheduler sc λ⊤ →', '    Task.sleep (Duration.millis 1)', '    bump r', 'Task.sleep (Duration.millis 5)', 'Log.info (ints (Ref.get r))'],
  spawnSchedHelper: () => ['_ = Task.spawn λ⊤ → under sc λ⊤ →', '    Task.sleep (Duration.millis 1)', '    bump r', 'Task.sleep (Duration.millis 5)', 'Log.info (ints (Ref.get r))'],
};

function genRunOn(other, writer, live) {
  const push = live ? 'List.push l 5' : 'List.push (List.copy l) 5';
  const body = ['r = Ref.make [ 1, 2 ]', 'sc = Task.scheduler λ⊤ → ⊤', ...(RUNON_OTHERS[other] ?? []), ...RUNON_WRITERS[writer](push), 'send Done'];
  return `-- runon.${other}.${writer}: see bench/ownership-sweeps/cells.mjs.
import Cmd exposing (Cmd)
import Duration
import Html exposing (Html)
import List
import Log
import Ref exposing (Ref)
import String
import Sub
import Task exposing (Scheduler)
import Tea


type Msg
    = Done


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


deep : Int → Int
deep n = if n < 0 then 0 else 1 + deep (n + 1)


masked : (⊤ → ⊤) → ⊤
masked f = Task.uninterruptible f


under : Scheduler, (⊤ → ⊤) → ⊤
under s f = Task.withScheduler s f


bump : Ref (List Int) → ⊤
bump h =
    Ref.update h λl →
        l2 = ${push}
        n = deep 0
        if n > 0 then l2 else l2


work : (Msg → ⊤) → ⊤
work send =
${ind(body.join('\n'), 4)}


init : ⊤ → Int × Cmd Msg
init ⊤ = ( 0, Cmd.perform work )


update : Msg, Int → Int × Cmd Msg
update msg model =
    case msg of
        Done →
            ( model + 1, Cmd.none )


view : Int → Html Msg
view model = <p>{model}</p>


main : Tea.Program
main = Tea.element { init = init, update = update, view = view, subscriptions = λ_ → Sub.none }
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
  if (fibers === 'midPark' && !(reader === 'loan' && holder === 'name')) continue;
  if (STORE.has(writer) && (!STORE_READERS.includes(reader) || (reader === 'loan' && !COND_HOLDERS.includes(holder)) || !STORE_FIBERS.includes(fibers))) continue;
  if (ARM.has(writer) && (!ARM_READERS.includes(reader) || (reader === 'loan' && !ARM_HOLDERS.includes(holder)) || !ARM_FIBERS.includes(fibers))) continue;
  if (MOVE.has(writer) && (cname !== 'pair' || !MOVE_READERS.includes(reader) || (reader === 'loan' && !ARM_HOLDERS.includes(holder)) || !ARM_FIBERS.includes(fibers))) continue;
  if (COND.has(writer) && (!COND_READERS.includes(reader) || (reader === 'loan' && !COND_HOLDERS.includes(holder)) || !COND_FIBERS.includes(fibers))) continue;
  const twin = isLive(writer, reader, fibers, holder) ? 'live' : 'dead';
  emit(`${cname}.${maker}.${writer}.${reader}.${holder}.${fibers}.${twin}`, { 'Main.beni': gen(cname, maker, writer, reader, holder, fibers) });
}
for (const cname of Object.keys(CONTENTS)) for (const wrap of ['maybe', 'result']) for (const op of ['fresh', 'arg', 'err']) for (const site of ['top', 'arm', 'local', 'park', 'unannot']) for (const use of ['read', 'argAfter', 'writeArg', 'fiber']) {
  if (op === 'err' && wrap !== 'result') continue;
  const twin = tryLive(op, use) ? 'live' : 'dead';
  emit(`try.${cname}.${wrap}.${op}.${site}.${use}.${twin}`, { 'Main.beni': genTry(cname, wrap, op, site, use) });
}
for (const write of Object.keys(ESC_WRITES)) for (const escape of Object.keys(ESC)) for (const runner of Object.keys(ESC_RUNNERS)) for (const n of [2, 1]) {
  const twin = n === 2 && escape !== 'none' && escape !== 'cell2last' ? 'live' : 'dead';
  emit(`esc.${write}.${escape}.${runner}.${n === 2 ? 'twice' : 'once'}.${twin}`, { 'Main.beni': genEsc(write, escape, runner, n) });
}
for (const shape of Object.keys(ESC2)) for (const runner of Object.keys(ESC_RUNNERS)) for (const n of [2, 1]) {
  emit(`esc2.${shape}.${runner}.${n === 2 ? 'twice' : 'once'}.${n === 2 ? 'live' : 'dead'}`, { 'Main.beni': genEsc2(shape, runner, n) });
}
for (const stored of Object.keys(PARK_STORED)) for (const park of Object.keys(PARK_POINTS)) for (const runner of ['direct', 'map', 'fold', 'scope']) for (const writer of ['fiber', 'self']) for (const live of [true, false]) {
  emit(`park.${stored}.${park}.${runner}.${writer}.${live ? 'live' : 'dead'}`, { 'Main.beni': genPark(stored, park, runner, writer, live) });
}
for (const outKind of READER_OUTS) for (const read of Object.keys(READER_READS)) for (const live of ['cellUpd', 'joined'].includes(outKind) ? [false] : [true, false]) {
  if (outKind === 'second' && read !== 'two') continue;
  emit(`reader.${outKind}.${read}.${live ? 'live' : 'dead'}`, { 'Main.beni': genReader(outKind, read, live) });
}
for (const log of Object.keys(MARK_LOGS)) for (const at of MARK_ATS) for (const live of [true, false]) {
  emit(`marked.${log}.${at}.${live ? 'live' : 'dead'}`, { 'Main.beni': genMarked(log, at, live) });
}
for (const hook of DEFECT_HOOKS) for (const at of DEFECT_ATS) for (const live of [true, false]) {
  if (!DEFECT_INSTALLED.includes(hook) && (at !== 'frame' || !live)) continue;
  emit(`defect.${hook}.${at}.${live ? 'live' : 'dead'}`, { 'Main.beni': genDefect(hook, at, live) });
}
for (const shape of Object.keys(REACH)) for (const at of DEFECT_ATS) for (const live of [true, false]) {
  emit(`reach.${shape}.${at}.${live ? 'live' : 'dead'}`, { 'Main.beni': genReach(shape, at, live) });
}
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const runon = [];
for (const other of Object.keys(RUNON_OTHERS)) for (const writer of ['frame', 'closure', 'helper', 'sched']) runon.push([other, writer]);
for (const writer of ['spawnSched', 'spawnSchedHelper']) runon.push(['frameRead', writer]);
if (runon.some(([o, w]) => `runon.${o}.${w}`.includes(filter))) {
  // The platform copy: `browser-inline` with no `"lists"` key, over the repository's `browser-base`.
  const plat = path.resolve(out, '_platform');
  fs.cpSync(path.join(root, 'platforms/browser-inline'), plat, { recursive: true });
  const man = JSON.parse(fs.readFileSync(path.join(plat, 'beni.json'), 'utf8'));
  delete man.lists;
  man.platforms = [path.relative(plat, path.join(root, 'platforms/browser-base'))];
  fs.writeFileSync(path.join(plat, 'beni.json'), JSON.stringify(man, null, 2) + '\n');
  for (const [other, writer] of runon) for (const live of [true, false]) {
    emit(`runon.${other}.${writer}.${live ? 'live' : 'dead'}`, { 'Main.beni': genRunOn(other, writer, live), PLATFORM: path.relative(root, plat) + '\n', steps: 'throws advance 2\nadvance 10\nadvance 100\n' });
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
