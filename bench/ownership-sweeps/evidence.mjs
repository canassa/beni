// evidence.mjs <outdir> [filter]: a generator for evidence that reaches a call the walk may not see (#2601,
// kernel §6 rule 11). A type's method (`Sink.add`, a `Bag`'s `eq`/`compare`, a `fromInts` reached by
// return-type dispatch) either writes the value it is handed (`write`) or only reads it (`read`, the
// control). It is handed as evidence (`where`) in one of several forms: to a top-level generic function
// directly, or through a local function generalised over the `where` (a lambda, a local definition, a
// `_` placeholder, two nested locals, a dot-call in a lambda, a local handed to `List.map`, called twice,
// held by a closure or a record, handed on to a second generic function, or made inside a generic
// function); operators over a user `eq`/`compare` (`==`, `≠`, `<`, `List.sort`, `List.member`, derived
// `eq` of a tuple, a `Maybe` and a list of the type). The written base is a list, a record, a `Dict` or a
// cell's contents. The `live` twin reads the base after the call, the `dead` one does not. A TRAP or DIFF
// of any program is a soundness hole; a refusal of a `read` program is a precision loss, and a refusal
// of a `write.dead` one is the rule (evidence that writes is refused where it is handed). Programs are
// `method.<base>.<act>.<form>.<twin>/`, `op.<act>.<form>.<twin>/` and `ret.<act>.<form>.<twin>/`.
// See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/evidence.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const HEAD = `import Dict exposing (Dict)
import Io
import List
import Node exposing (Program)
import Ref exposing (Ref)
import String


yn : Bool → String
yn b = if b then "t" else "f"


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


renderD : Dict Int Int → String
renderD d =
    String.join (List.map (Dict.toList d) λ( k, v ) → "\${String.fromInt k}=\${String.fromInt v}") ","


type alias R =
    { n : Int, m : Int }


showR : R → String
showR r = "\${String.fromInt r.n}/\${String.fromInt r.m}"
`;

// Each base: its type, how it is made, the method's body that writes it and the one that reads it,
// and how a value of it is shown.
const BASES = {
  list: { t: 'List Int', mk: '[ 1, 2 ]', write: 'List.push l 5', read: 'List.map l λx → x + 1', show: (v) => `ints ${v}` },
  rec: { t: 'R', mk: '{ n = 1, m = 2 }', write: '{ l | n = 5 }', read: '{ n = l.n + 1, m = l.m }', show: (v) => `showR ${v}` },
  dict: { t: 'Dict Int Int', mk: 'Dict.fromList [ ( 1, 10 ), ( 2, 20 ) ]', write: 'Dict.insert l 3 30', read: 'Dict.fromList (Dict.toList l)', show: (v) => `renderD ${v}` },
  cell: { t: 'Ref (List Int)', mk: 'Ref.make [ 1, 2 ]', write: 'Ref.update l λc → List.push c 5\nl', read: 'Ref.make (List.map (Ref.get l) λx → x + 1)', show: (v) => `ints (Ref.get ${v})` },
};

// How the method reaches the call: lines of `go` that bind `x`, and top-level helpers.
const FORMS = {
  direct: { lines: ['x = addOnce Sink b0'] },
  lam: { lines: ['f = λk → addOnce k b0', 'x = f Sink'] },
  localFn: { lines: ['f k = addOnce k b0', 'x = f Sink'] },
  partial: { lines: ['f = addOnce _ b0', 'x = f Sink'] },
  nested: { lines: ['h = λk → addOnce k b0', 'f = λk → h k', 'x = f Sink'] },
  dot: { lines: ['f = λk → k.add b0', 'x = f Sink'] },
  twice: { lines: ['f = λk → addOnce k b0', 'x0 = f Sink', 'x = f Sink'] },
  mapped: { lines: ['f = λk → addOnce k b0', 'x = Maybe.withDefault (List.head (List.map [ Sink ] f)) b0'] },
  closure: { lines: ['f = λk → addOnce k b0', 'g = λ⊤ → f Sink', 'x = g ⊤'] },
  record: { lines: ['f = λk → addOnce k b0', 'c = { run = f }', 'x = c.run Sink'] },
  passOn: { lines: ['f = λk → viaOnce k b0', 'x = f Sink'] },
  outer: { lines: ['x = outer Sink b0'] },
};

function method(base, act, form, live) {
  const b = BASES[base];
  const t = b.t;
  const lines = ['b0 = ' + b.mk];
  if (base === 'cell') lines.push('y = Ref.get b0');
  lines.push(...FORMS[form].lines);
  const shown = [b.show('x')];
  if (live) shown.push(base === 'cell' ? 'ints y' : b.show('b0'));
  lines.push(`[ ${shown.join(', ')} ]`);
  return `${HEAD}

type Sink
    = Sink


pub add : Sink, ${t} → ${t}
add _ l =
${ind(b[act], 4)}


addOnce : a, ${t} → ${t}
    where a.add : a, ${t} → ${t}
addOnce k l = k.add l


viaOnce : a, ${t} → ${t}
    where a.add : a, ${t} → ${t}
viaOnce k l = addOnce k l


outer : a, ${t} → ${t}
    where a.add : a, ${t} → ${t}
outer k l =
    f = λj → addOnce j l
    f k


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

// Operators over a user `eq`/`compare`: lines that bind `s`, a `String`.
const OPS = {
  directEq: ['s = yn (Bag b0 == Bag [ 1 ])'],
  lamEq: ['f = λp q → p == q', 's = yn (f (Bag b0) (Bag [ 1 ]))'],
  lamNe: ['f = λp q → p ≠ q', 's = yn (f (Bag b0) (Bag [ 1 ]))'],
  localEq: ['f p q = p == q', 's = yn (f (Bag b0) (Bag [ 1 ]))'],
  lamLt: ['f = λp q → p < q', 's = yn (f (Bag b0) (Bag [ 1 ]))'],
  lamSort: ['f = λl → List.sort l', 's = String.fromInt (List.length (f [ Bag b0, Bag [ 1 ] ]))'],
  lamMember: ['f = λl v → List.member l v', 's = yn (f [ Bag [ 1 ] ] (Bag b0))'],
  partialMember: ['f = List.member _ (Bag b0)', 's = yn (f [ Bag [ 1 ] ])'],
  derTuple: ['f = λp q → p == q', 's = yn (f ( Bag b0, 1 ) ( Bag [ 1 ], 1 ))'],
  derMaybe: ['f = λp q → p == q', 's = yn (f (Just (Bag b0)) (Just (Bag [ 1 ])))'],
  derList: ['f = λp q → p == q', 's = yn (f [ Bag b0 ] [ Bag [ 1 ] ])'],
  nestedEq: ['h = λp q → p == q', 'f = λp q → h p q', 's = yn (f (Bag b0) (Bag [ 1 ]))'],
};

function op(act, form, live) {
  const x = act === 'write' ? 'List.push x 0' : 'x';
  const lines = ['b0 = [ 1, 2 ]', ...OPS[form]];
  lines.push(`[ ${['s', ...(live ? ['ints b0'] : [])].join(', ')} ]`);
  return `${HEAD}

type Bag
    = Bag (List Int)


pub compare : Bag, Bag → Order
compare a b =
    case ( a, b ) of
        ( Bag x, Bag y ) → (List.length (${x})).compare (List.length y)


pub eq : Bag, Bag → Bool
eq a b =
    case ( a, b ) of
        ( Bag x, Bag y ) → List.length (${x}) == List.length y


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

// Return-type dispatch: lines that bind `b : Bag`.
const RETS = {
  direct: ['b : Bag', 'b = build b0'],
  lam: ['f = λl → build l', 'b : Bag', 'b = f b0'],
  localFn: ['f l = build l', 'b : Bag', 'b = f b0'],
  nested: ['h = λl → build l', 'f = λl → h l', 'b : Bag', 'b = f b0'],
};

function ret(act, form, live) {
  const lines = ['b0 = [ 1, 2 ]', ...RETS[form]];
  lines.push(`[ ${['ints (unbag b)', ...(live ? ['ints b0'] : [])].join(', ')} ]`);
  return `${HEAD}

type Bag
    = Bag (List Int)


pub fromInts : List Int → Bag
fromInts l = Bag (${act === 'write' ? 'List.push l 5' : 'List.map l λx → x + 1'})


build : List Int → a
    where a.fromInts : List Int → a
build l = a.fromInts l


unbag : Bag → List Int
unbag b =
    case b of
        Bag l → l


go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = Io.run λ⊤ → Node.printLines (go ⊤)
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
function emit(name, text) {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), text);
  list.push(path.resolve(d));
}
for (const act of ['write', 'read']) for (const live of [false, true]) {
  const twin = live ? 'live' : 'dead';
  for (const base of Object.keys(BASES)) for (const form of Object.keys(FORMS)) emit(`method.${base}.${act}.${form}.${twin}`, method(base, act, form, live));
  for (const form of Object.keys(OPS)) emit(`op.${act}.${form}.${twin}`, op(act, form, live));
  for (const form of Object.keys(RETS)) emit(`ret.${act}.${form}.${twin}`, ret(act, form, live));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
