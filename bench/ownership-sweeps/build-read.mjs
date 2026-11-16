// build-read.mjs <outdir> [filter]: research report 148, every way a value is built crossed with every way it
// is read. Reports 146 and 147 found one mistake in three code paths: where the checker had no fact about a
// part of a value, it answered "holds nothing" in place of "could hold anything" (ownership-v3-kernel.md §1,
// §3, §3.4). Each was found by a blind reader one shape at a time. This sweep crosses the shapes.
//
// A program makes an item `x0` (a list, or a record of numbers), puts it in a container `c` in one of the ways
// a value is built, takes it out of `c` again in one of the ways a value is read, and writes what it took out
// in place (a push, or an update of `k`). Names are `<shape>.<maker>.<reader>.<item>.<twin>`:
//
// - shapes: `rec` (a record alias `P t` of fields `a`, `b`), `ctor` (`type C t = C Int t`), `tup`
//   (`Int × t`), `list` (`List t`). The first three are one JavaScript object of properties `a` and `b`
//   (`backend.md` §4), so a `Js.to` can read each as another.
// - makers: the shape's own literal (`lit`), a record alias's constructor (`aliasCtor`), `Js.to` of the
//   same shape (`jsTo`), `Js.to` of another shape (`castTup`, `castRec`, `castCtor`; a constructor's value
//   carries its tag, so a constructor is read as a record or a tuple, never the other way), a core function's
//   answer (`core`: `Maybe.withDefault`, `List.reverse`), a generic helper's answer (`generic`), a closure's
//   capture (`closure`: a lambda that builds the value from what it captured, called), and the shape's
//   literal read as an `Int` by a helper and back through `Js.to` (`viaInt`: a type of no cell between).
// - readers: a field read (`field`), a record pattern (`recPat`), a constructor pattern in `case`, `let`,
//   `as`, a parameter and a lambda (`ctorCase`, `ctorLet`, `ctorAs`, `ctorParam`, `ctorLambda`; a record
//   alias's constructor for `rec`), a tuple pattern in the same four forms (`tupCase`, `tupLet`, `tupParam`,
//   `tupLambda`), a list pattern (`head`, and `rest`, which takes the item out of `…rest`), the base of an
//   update (`updBase`: the item read out of the update's answer), and a generic projection (`generic`).
// - items: `list` (written by `List.push`) and `rec` (written by `{ y | k = 5 }`).
// - twins: `live` reads `x0` after the write, `kept` reads the container `c` after it (its item and its
//   field `a`), `dead` reads neither. A `live` or `kept` program the checker accepts must print what the
//   plain build prints (bench/ownership-sweeps/README.md).
//
// The `Js.to` makers use a test platform written next to the programs (`_buildread`).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/build-read.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const indent = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const ITEM = {
  list: { ty: 'List Int', make: '[ n ]', dummy: '[ 0 ]', write: (y) => `List.length (List.push ${y} 9)`, read: (y) => `List.length ${y}` },
  rec: { ty: 'R', make: '{ k = n, m = 1 }', dummy: '{ k = 0, m = 0 }', write: (y) => `({ ${y} | k = 5 }).k`, read: (y) => `${y}.k` },
};

// The literal of a shape, with the item at its place (`list` takes the order of its elements).
const LIT = {
  rec: (x) => `{ a = 1, b = ${x} }`,
  ctor: (x) => `C 1 ${x}`,
  tup: (x) => `( 1, ${x} )`,
  list: (x, order) => (order === 'rest' ? `[ d, ${x} ]` : `[ ${x}, d ]`),
};
const TYPE = { rec: (t) => `P (${t})`, ctor: (t) => `C (${t})`, tup: (t) => `Int × ${t}`, list: (t) => `List (${t})` };
const GENERIC_MAKE = { rec: 'mkP', ctor: 'mkC', tup: 'mkT', list: 'mkL' };

// Each maker: statements that bind `c`, or null where it does not apply to the shape.
const MAKER = {
  lit: (s, it, o) => `c = ${LIT[s]('x0', o)}`,
  aliasCtor: (s) => (s === 'rec' ? 'c = P 1 x0' : null),
  jsTo: (s, it, o) => `c : ${TYPE[s](it.ty)}\nc = Pun.conv (${LIT[s]('x0', o)})`,
  castTup: (s, it) => (s === 'rec' ? `c : ${TYPE[s](it.ty)}\nc = Pun.conv ( 1, x0 )` : null),
  castRec: (s, it) => (s === 'tup' ? `c : ${TYPE[s](it.ty)}\nc = Pun.conv { a = 1, b = x0 }` : null),
  castCtor: (s, it) => (s === 'tup' || s === 'rec' ? `c : ${TYPE[s](it.ty)}\nc = Pun.conv (C 1 x0)` : null),
  core: (s, it, o) => (s === 'list' ? `c = List.reverse (${o === 'rest' ? '[ x0, d ]' : '[ d, x0 ]'})` : `c = Maybe.withDefault (Just (${LIT[s]('x0')})) (${LIT[s]('d')})`),
  generic: (s, it, o) => (s === 'list' ? `c = ${o === 'rest' ? 'mkL d x0' : 'mkL x0 d'}` : `c = ${GENERIC_MAKE[s]} x0`),
  closure: (s, it, o) => `g = λ⊤ → ${LIT[s]('x0', o)}\nc = g ⊤`,
  viaInt: (s, it, o) => `c : ${TYPE[s](it.ty)}\nc = Pun.conv (hide (${LIT[s]('x0', o)}))`,
};

// Each reader: statements that bind `x`, the write of the item read out of `c`; `decls` are helpers it needs.
const READER = {
  rec: {
    field: (w) => ({ body: `y = c.b\nx = ${w('y')}` }),
    recPat: (w) => ({ body: `x = case c of\n    { b } →\n        ${w('b')}` }),
    ctorCase: (w) => ({ body: `x = case c of\n    P _ y →\n        ${w('y')}` }),
    ctorLet: (w) => ({ body: `(P _ y) = c\nx = ${w('y')}` }),
    ctorAs: (w) => ({ body: `x = case c of\n    ((P _ y) as whole) →\n        ${w('y')} + whole.a` }),
    ctorParam: (w, t) => ({ decls: `rd : P (${t}) → Int\nrd (P _ y) =\n    ${w('y')}\n`, body: 'x = rd c' }),
    ctorLambda: (w) => ({ body: `f = λ(P _ y) → ${w('y')}\nx = f c` }),
    updBase: (w) => ({ body: `c2 = { c | a = 7 }\ny = c2.b\nx = ${w('y')} + c2.a` }),
    generic: (w) => ({ body: `y = gb c\nx = ${w('y')}` }),
  },
  ctor: {
    ctorCase: (w) => ({ body: `x = case c of\n    C _ y →\n        ${w('y')}` }),
    ctorLet: (w) => ({ body: `(C _ y) = c\nx = ${w('y')}` }),
    ctorAs: (w) => ({ body: `x = case c of\n    ((C m y) as whole) →\n        ${w('y')} + m + (case whole of\n            C q _ →\n                q)` }),
    ctorParam: (w, t) => ({ decls: `rd : C (${t}) → Int\nrd (C _ y) =\n    ${w('y')}\n`, body: 'x = rd c' }),
    ctorLambda: (w) => ({ body: `f = λ(C _ y) → ${w('y')}\nx = f c` }),
    generic: (w) => ({ body: `y = unC c\nx = ${w('y')}` }),
  },
  tup: {
    tupCase: (w) => ({ body: `x = case c of\n    ( _, y ) →\n        ${w('y')}` }),
    tupLet: (w) => ({ body: `( _, y ) = c\nx = ${w('y')}` }),
    tupParam: (w, t) => ({ decls: `rd : Int × ${t} → Int\nrd ( _, y ) =\n    ${w('y')}\n`, body: 'x = rd c' }),
    tupLambda: (w) => ({ body: `f = λ( _, y ) → ${w('y')}\nx = f c` }),
    generic: (w) => ({ body: `y = snd c\nx = ${w('y')}` }),
  },
  list: {
    head: (w) => ({ body: `x = case c of\n    [ y, …_ ] →\n        ${w('y')}\n\n    [] →\n        0`, order: 'head' }),
    rest: (w) => ({ body: `x = case c of\n    [ _, …rest ] →\n        case rest of\n            [ y, …_ ] →\n                ${w('y')}\n\n            [] →\n                0\n\n    [] →\n        0`, order: 'rest' }),
    generic: (w) => ({ body: `y = firstOr d c\nx = ${w('y')}`, order: 'head' }),
  },
};

// What the `kept` twin reads of the container after the write: its item, and its number.
const KEPT = {
  rec: (r) => `${r('c.b')} + c.a`,
  ctor: (r) => `case c of\n    C m q →\n        m + ${r('q')}`,
  tup: (r) => `case c of\n    ( m, q ) →\n        m + ${r('q')}`,
  list: (r) => `List.sum (List.map c (λq → ${r('q')}))`,
};

const DECLS = `type alias P t =
    a : Int
    b : t


type C t
    = C Int t


type alias R =
    k : Int
    m : Int


mkP : t → P t
mkP x =
    P 1 x


mkC : t → C t
mkC x =
    C 1 x


mkT : t → Int × t
mkT x =
    ( 1, x )


mkL : t, t → List t
mkL x y =
    [ x, y ]


gb : { r | b : t } → t
gb r =
    r.b


snd : x × t → t
snd ( _, y ) =
    y


unC : C t → t
unC (C _ y) =
    y


hide : t → Int
hide v =
    Pun.conv v


firstOr : t, List t → t
firstOr z xs =
    case xs of
        [ y, …_ ] →
            y

        [] →
            z
`;

const progs = [];
for (const [shape, readers] of Object.entries(READER)) for (const maker of Object.keys(MAKER)) for (const [rname, reader] of Object.entries(readers)) for (const [iname, it] of Object.entries(ITEM)) {
  const r = reader(it.write, it.ty);
  const made = MAKER[maker](shape, it, r.order);
  if (made === null) continue;
  for (const twin of ['live', 'kept', 'dead']) {
    const name = `${shape}.${maker}.${rname}.${iname}.${twin}`;
    if (filter && !name.includes(filter)) continue;
    const after = twin === 'live' ? it.read('x0') : twin === 'kept' ? KEPT[shape](it.read) : '0';
    const body = [`x0 = ${it.make}`, `d = ${it.dummy}`, made, r.body, `v =\n${indent(after, 4)}`, '"${String.fromInt x} ${String.fromInt v}"'].join('\n');
    const go = `go : Int → String\ngo n =\n${indent(body, 4)}\n`;
    const main = [`import Node exposing (Program)\nimport Pun\n`, DECLS, ...(r.decls ? [r.decls] : []), go, 'main : Program\nmain = Node.print (go 0)\n'].join('\n\n');
    progs.push({ name, main });
  }
}

const platformDir = path.join(path.resolve(out), '_buildread');
const platformRel = path.relative(root, platformDir);
fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "buildread", "platforms": ["node"], "reexports": ["Node"] }\n');
fs.writeFileSync(path.join(platformDir, 'Pun.beni'), `--! A sweep's platform: a value read at another type of the same JavaScript shape.\n\nimport Js\n\n\npub conv : a → b\nconv v =\n    Js.to (Js.from v)\n`);
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  fs.writeFileSync(path.join(d, 'PLATFORM'), `${platformRel}\n`);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
