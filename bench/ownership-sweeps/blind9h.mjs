// blind9h.mjs <outdir> [filter]: research report 132, a ninth blind test (reader H).
//
// Four parts. A filter (the second argument) keeps the programs whose name contains it.
//
// `rand.*`: seeded typed random programs (`BLIND9H_RANDS`, default 1500; `BLIND9H_FROM`, default 0).
// Each is one function `go` that binds 6 to 14 values of ten types (a list, a list of lists, a
// record of two lists, a pair, a `Maybe`, a function of `⊤`, a constructor of a type with methods,
// a recursive tree, a record that holds a function, a generic record) through about 110
// operations: literals, writes of `core/` (`push`, `set`, `pop`, `update`, `swap`, `insertAt`,
// `removeAt`, a spread, `++`), about 45 helpers (identity, generic identity and choice, pick, a
// pair or record maker, folds, recursion that swaps, a closure that keeps its list, a callback
// runner, a rest view, `Maybe`, `Dict`, `Ref`, functions over a row, a tree walker, methods),
// lambdas, `if`, `case` and record update. Each value is read at most once by later operations,
// except with a seeded chance; a random subset of the names is printed at the end. The twin kind is
// `live` when a name bound before the last write is read after it, `dead` otherwise. Half the
// programs keep the helpers in a second module.
//
// `alias.*`: one value of a type written with nested generic aliases (`Box`, `Pair`, `Twin`,
// `Deep`, `Tri`, a row alias `Holds`), read at one path and written at a path, directly, through a
// generic identity, through a join of two values or through a pair (`BLIND9H_ALIASES`, default
// 1500). Decoy functions read the same aliases at other arguments first. Half keep the aliases
// in a second module. `live`: the read path meets the written one; `apart`: it does not.
//
// `tea.<saver>.<write>.<twin>`: 144 `browser-tea` pages: `update` writes `model.items` in place on
// `Add`, after `Save` kept something made from it in `model.saved` (24 savers × 3 writes).
//
// `hand.*`: 69 hand-written probes: a schema's constructor called, partly applied, as a value, mapped
// and printed; a `via` whose conversion writes; a derived `eq` that calls a writing `eq`; one cell at two positions of a list made by 16 functions of `core/`; the answer
// of a `taken` callback; `Ref.update` and `Ref.modify`; `Task.spawn`, `par`, `scope` and
// `forEach` with waits; closures that answer closures 4 to 20 deep; code that no call reaches
// (for the check of kernel §6.14); a prepend that gives back its base's array.
//
// See bench/ownership-sweeps/README.md and docs/design/research/132-ownership-kernel-blind-reader-h.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind9h.mjs <outdir> [filter]'); process.exit(2); }
const RANDS = Number(process.env.BLIND9H_RANDS ?? 1500);
const FROM = Number(process.env.BLIND9H_FROM ?? 0);
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

fs.mkdirSync(out, { recursive: true });
const list = [];
function emit(name, files) {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, s] of Object.entries(files)) fs.writeFileSync(path.join(d, f), s);
  list.push(path.resolve(d));
}

// ---- rand -------------------------------------------------------------------------------------

function rng(seed) {
  let s = (seed * 2654435761 + 12345) >>> 0;
  return () => {
    s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}

// The helpers. `H` is the module prefix (`` or `H.`).
const HELPERS = `idL : List Int → List Int
idL l = l


pushH : List Int → List Int
pushH l = List.push l 1


setH : List Int → List Int
setH l = List.set l 0 5


pick : Bool, List Int, List Int → List Int
pick b x y = if b then x else y


wrapR : List Int, List Int → R
wrapR x y = { a = x, b = y }


dupP : List Int → List Int × List Int
dupP l = ( l, l )


swapP : List Int × List Int → List Int × List Int
swapP ( x, y ) = ( y, x )


fstP : List Int × List Int → List Int
fstP ( x, _ ) = x


sndP : List Int × List Int → List Int
sndP ( _, y ) = y


keepF : List Int → (⊤ → List Int)
keepF l = λ⊤ → l


runF : (⊤ → List Int) → List Int
runF f = f ⊤


appF : (List Int → List Int), List Int → List Int
appF g l = g l


nest : List Int, List Int → List (List Int)
nest x y = [ x, y ]


headL : List (List Int) → List Int
headL ll =
    case ll of
        [ x, …_ ] →
            x

        [] →
            []


pushAll : List (List Int) → List (List Int)
pushAll ll = List.map ll λl → List.push l 7


foldInto : List Int, List Int → List Int
foldInto xs acc = List.foldl xs acc λq a → List.push a q


recPush : Int, List Int → List Int
recPush n l =
    if n ≤ 0 then
        l
    else
        recPush (n - 1) (List.push l n)


updR : R → R
updR r = { r | a = List.push r.a 3 }


maybeL : List Int → Maybe (List Int)
maybeL l =
    if List.length l > 100 then
        Nothing
    else
        Just l


fromM : Maybe (List Int) → List Int
fromM m =
    case m of
        Just v →
            v

        Nothing →
            []


restL : List Int → List Int
restL l =
    case l of
        [ _, …rest ] →
            rest

        [] →
            []


spreadL : List Int, List Int → List Int
spreadL x y = [ …x, …y ]


snocL : List Int → List Int
snocL x = [ …x, 4 ]


consL : List Int → List Int
consL x = [ 0, …x ]


viaDict : List Int → List Int
viaDict l =
    d = Dict.insert Dict.empty 1 l
    Dict.get d 1 ▷ Maybe.withDefault []


viaRef : List Int → List Int
viaRef l = Ref.get (Ref.make l)


twiceF : (List Int → List Int), List Int → List Int
twiceF g l = g (g l)


both : (List Int → List Int), List Int × List Int → List Int × List Int
both g ( x, y ) = ( g x, g y )


pub type Box
    = Box (List Int)


pub grow : Box → Box
grow (Box l) = Box (List.push l 8)


pub items : Box → List Int
items (Box l) = l


pub peek : Box → List Int
peek b = items b


idA : a → a
idA x = x


chooseA : Bool, a, a → a
chooseA b x y = if b then x else y


pairA : a, a → a × a
pairA x y = ( x, y )


firstA : a × b → a
firstA ( x, _ ) = x


applyA : (a → a), a → a
applyA g x = g x


getOr : Maybe a, a → a
getOr m d =
    case m of
        Just x →
            x

        Nothing →
            d


wrapA : a → { v : a }
wrapA x = { v = x }


unwrapA : { v : a } → a
unwrapA w = w.v


getRow : { r | a : List Int } → List Int
getRow x = x.a


setRow : { r | a : List Int }, List Int → { r | a : List Int }
setRow x l = { x | a = l }


pushRow : { r | a : List Int } → { r | a : List Int }
pushRow x = { x | a = List.push x.a 1 }


pub type Tree
    = Leaf (List Int)
    | Node Tree Tree


leftmost : Tree → List Int
leftmost t =
    case t of
        Leaf l →
            l

        Node x _ →
            leftmost x


rightmost : Tree → List Int
rightmost t =
    case t of
        Leaf l →
            l

        Node _ y →
            rightmost y


pushLeaves : Tree → Tree
pushLeaves t =
    case t of
        Leaf l →
            Leaf (List.push l 2)

        Node x y →
            Node (pushLeaves x) (pushLeaves y)


mkTree : List Int, List Int → Tree
mkTree x y = Node (Leaf x) (Leaf y)


swapFold : List Int × List Int → List Int × List Int
swapFold p = List.foldl [ 1, 2, 3 ] p λq ( s, t ) → ( t, List.push s q )


getC : { get : ⊤ → List Int } → List Int
getC c = c.get ⊤


mkC : List Int → { get : ⊤ → List Int }
mkC l = { get = λ⊤ → l }


recSwap : Int, List Int, List Int → List Int
recSwap k x y =
    if k ≤ 0 then
        x
    else
        recSwap (k - 1) (List.push y k) x


dictPush : List Int → List Int
dictPush l =
    d = Dict.insert Dict.empty 1 l
    d2 = Dict.update d 1 λm → Maybe.map m λz → List.push (List.copy z) 3
    getOr (Dict.get d2 1) []
`;

function makeRand(seed) {
  const R = rng(seed + 1);
  const pickA = (a) => a[Math.floor(R() * a.length)];
  const mod = R() < 0.5;
  const H = mod ? 'H.' : '';
  const env = { L: [], LL: [], R: [], P: [], M: [], F: [], B: [], T: [], C: [], W: [] };
  const lines = [];
  let k = 0;
  let lastWrite = -1;
  const bornAt = {};
  const uses = {};
  const v = (t) => {
    if (!env[t].length) return null;
    const fresh = env[t].filter((x) => !uses[x]);
    const x = fresh.length && R() > reuse ? fresh[fresh.length - 1 - Math.floor(R() * Math.min(2, fresh.length))] : pickA(env[t]);
    uses[x] = (uses[x] ?? 0) + 1;
    return x;
  };
  const reuse = [0.05, 0.15, 0.3][Math.floor(R() * 3)];
  const refs = [];
  const ops = [
    // [type, writes, maker]
    ['L', 0, () => `[ n, ${Math.floor(R() * 9)} ]`],
    ['L', 0, () => `List.range 1 n`],
    ['L', 0, () => v('L') && `${H}idL ${v('L')}`],
    ['L', 1, () => v('L') && `${H}pushH ${v('L')}`],
    ['L', 1, () => v('L') && `${H}setH ${v('L')}`],
    ['L', 1, () => v('L') && `List.push ${v('L')} 9`],
    ['L', 1, () => v('L') && `List.set ${v('L')} 0 n`],
    ['L', 1, () => v('L') && `List.pop ${v('L')}`],
    ['L', 1, () => v('L') && `List.update ${v('L')} 0 λq → q + 1`],
    ['L', 1, () => v('L') && `List.swap ${v('L')} 0 1`],
    ['L', 1, () => v('L') && `List.insertAt ${v('L')} 1 6`],
    ['L', 1, () => v('L') && `List.removeAt ${v('L')} 0`],
    ['L', 1, () => v('L') && `[ …${v('L')}, 3 ]`],
    ['L', 1, () => v('L') && `${v('L')} ++ ${v('L')}`],
    ['L', 0, () => v('L') && `${H}pick (n > 0) ${v('L')} ${v('L')}`],
    ['L', 0, () => v('P') && `${H}fstP ${v('P')}`],
    ['L', 0, () => v('P') && `${H}sndP ${v('P')}`],
    ['L', 0, () => v('R') && `${v('R')}.a`],
    ['L', 0, () => v('R') && `${v('R')}.b`],
    ['L', 0, () => v('F') && `${H}runF ${v('F')}`],
    ['L', 0, () => v('F') && `${v('F')} ⊤`],
    ['L', 1, () => v('L') && `${H}appF ${H}pushH ${v('L')}`],
    ['L', 1, () => v('L') && `${H}appF (λl → List.push l 4) ${v('L')}`],
    ['L', 1, () => v('L') && `${H}twiceF (λl → List.set l 0 2) ${v('L')}`],
    ['L', 0, () => v('LL') && `${H}headL ${v('LL')}`],
    ['L', 1, () => v('L') && `${H}foldInto ${v('L')} ${v('L')}`],
    ['L', 1, () => v('L') && `${H}recPush 2 ${v('L')}`],
    ['L', 0, () => v('M') && `${H}fromM ${v('M')}`],
    ['L', 0, () => v('L') && `${H}restL ${v('L')}`],
    ['L', 1, () => v('L') && `${H}spreadL ${v('L')} ${v('L')}`],
    ['L', 1, () => v('L') && `${H}snocL ${v('L')}`],
    ['L', 0, () => v('L') && `${H}consL ${v('L')}`],
    ['L', 0, () => v('L') && `List.copy ${v('L')}`],
    ['L', 0, () => v('L') && `List.map ${v('L')} λq → q * 2`],
    ['L', 0, () => v('L') && `List.reverse ${v('L')}`],
    ['L', 0, () => v('L') && `List.drop ${v('L')} 1`],
    ['L', 1, () => v('L') && `if n > 1 then List.push ${v('L')} 1 else ${v('L')}`],
    ['L', 0, () => v('L') && `${H}viaDict ${v('L')}`],
    ['L', 0, () => v('L') && `${H}viaRef ${v('L')}`],
    ['L', 0, () => v('B') && `${H}items ${v('B')}`],
    ['L', 0, () => v('B') && `${v('B')}.peek`],
    ['L', 0, () => v('LL') && `List.get ${v('LL')} 1 ▷ Maybe.withDefault []`],
    ['L', 0, () => v('L') && `List.foldl ${v('L')} ${v('L')} λq a → if q > 100 then a else a`],
    ['L', 1, () => v('L') && `List.foldl [ 1, 2 ] ${v('L')} λq a → List.push a q`],
    ['L', 0, () => v('L') && `case ${v('L')} of\n    [ _, …r ] →\n        r\n\n    [] →\n        ${v('L')}`],
    ['LL', 0, () => v('L') && `${H}nest ${v('L')} ${v('L')}`],
    ['LL', 0, () => v('L') && `[ ${v('L')}, ${v('L')} ]`],
    ['LL', 1, () => v('LL') && `${H}pushAll ${v('LL')}`],
    ['LL', 1, () => v('LL') && v('L') && `List.push ${v('LL')} ${v('L')}`],
    ['LL', 1, () => v('LL') && `List.map ${v('LL')} λl → List.push l 1`],
    ['LL', 1, () => v('LL') && v('L') && `List.set ${v('LL')} 0 ${v('L')}`],
    ['LL', 1, () => v('LL') && `List.update ${v('LL')} 0 λl → List.push l 2`],
    ['R', 0, () => v('L') && `${H}wrapR ${v('L')} ${v('L')}`],
    ['R', 0, () => v('L') && `{ a = ${v('L')}, b = ${v('L')} }`],
    ['R', 1, () => v('R') && `${H}updR ${v('R')}`],
    ['R', 0, () => v('R') && v('L') && `{ ${v('R')} | b = ${v('L')} }`],
    ['R', 1, () => v('R') && `{ ${v('R')} | a = List.push ${v('R')}.a 2 }`],
    ['P', 0, () => v('L') && `${H}dupP ${v('L')}`],
    ['P', 0, () => v('L') && `( ${v('L')}, ${v('L')} )`],
    ['P', 0, () => v('P') && `${H}swapP ${v('P')}`],
    ['P', 1, () => v('P') && `${H}both ${H}pushH ${v('P')}`],
    ['M', 0, () => v('L') && `${H}maybeL ${v('L')}`],
    ['M', 0, () => v('L') && `Just ${v('L')}`],
    ['M', 1, () => v('M') && `Maybe.map ${v('M')} λl → List.push l 5`],
    ['F', 0, () => v('L') && `${H}keepF ${v('L')}`],
    ['F', 0, () => v('L') && `λ⊤ → ${v('L')}`],
    ['F', 0, () => v('L') && `λ⊤ → List.copy ${v('L')}`],
    ['B', 0, () => v('L') && `${H}Box ${v('L')}`],
    ['B', 1, () => v('B') && `${v('B')}.grow`],
    ['B', 1, () => v('B') && `${H}grow ${v('B')}`],
    ['L', 0, () => v('L') && `${H}idA ${v('L')}`],
    ['LL', 0, () => v('LL') && `${H}idA ${v('LL')}`],
    ['R', 0, () => v('R') && `${H}idA ${v('R')}`],
    ['L', 0, () => v('L') && `${H}chooseA (n > 2) ${v('L')} ${v('L')}`],
    ['R', 0, () => v('R') && `${H}chooseA (n > 2) ${v('R')} ${v('R')}`],
    ['P', 0, () => v('P') && `${H}chooseA (n > 2) ${v('P')} ${v('P')}`],
    ['T', 0, () => v('T') && `${H}chooseA (n > 2) ${v('T')} ${v('T')}`],
    ['P', 0, () => v('L') && `${H}pairA ${v('L')} ${v('L')}`],
    ['L', 0, () => v('P') && `${H}firstA ${v('P')}`],
    ['L', 1, () => v('L') && `${H}applyA ${H}pushH ${v('L')}`],
    ['R', 1, () => v('R') && `${H}applyA ${H}updR ${v('R')}`],
    ['L', 0, () => v('M') && v('L') && `${H}getOr ${v('M')} ${v('L')}`],
    ['W', 0, () => v('L') && `${H}wrapA ${v('L')}`],
    ['W', 0, () => v('L') && `{ v = ${v('L')} }`],
    ['L', 0, () => v('W') && `${H}unwrapA ${v('W')}`],
    ['L', 0, () => v('W') && `${v('W')}.v`],
    ['W', 1, () => v('W') && `{ ${v('W')} | v = List.push ${v('W')}.v 6 }`],
    ['L', 0, () => v('R') && `${H}getRow ${v('R')}`],
    ['R', 0, () => v('R') && v('L') && `${H}setRow ${v('R')} ${v('L')}`],
    ['R', 1, () => v('R') && `${H}pushRow ${v('R')}`],
    ['T', 0, () => v('L') && `${H}mkTree ${v('L')} ${v('L')}`],
    ['T', 0, () => v('T') && `${H}Node ${v('T')} ${v('T')}`],
    ['T', 0, () => v('L') && `${H}Leaf ${v('L')}`],
    ['T', 1, () => v('T') && `${H}pushLeaves ${v('T')}`],
    ['L', 0, () => v('T') && `${H}leftmost ${v('T')}`],
    ['L', 0, () => v('T') && `${H}rightmost ${v('T')}`],
    ['P', 1, () => v('P') && `${H}swapFold ${v('P')}`],
    ['C', 0, () => v('L') && `${H}mkC ${v('L')}`],
    ['C', 0, () => v('L') && `{ get = λ⊤ → ${v('L')} }`],
    ['L', 0, () => v('C') && `${H}getC ${v('C')}`],
    ['L', 0, () => v('C') && `${v('C')}.get ⊤`],
    ['L', 1, () => v('L') && `${H}recSwap 3 ${v('L')} ${v('L')}`],
    ['L', 1, () => v('L') && `${H}dictPush ${v('L')}`],
    ['L', 0, () => v('M') && v('L') && `case ${v('M')} of\n    Just z →\n        z\n\n    Nothing →\n        ${v('L')}`],
    ['L', 0, () => v('T') && `case ${v('T')} of\n    ${H}Leaf z →\n        z\n\n    ${H}Node _ _ →\n        []`],
    ['P', 0, () => v('P') && `case ${v('P')} of\n    ( z, w ) →\n        ( w, z )`],
    ['L', 1, () => v('L') && `List.foldl [ 1, 2 ] ${v('L')} λq a → ${H}pushH a`],
    ['L', 1, () => v('L') && `${H}runF (λ⊤ → List.push ${v('L')} 3)`],
    ['L', 0, () => v('LL') && `List.foldl ${v('LL')} [] λq a → q`],
    ['L', 0, () => v('LL') && `List.concat ${v('LL')}`],
    ['LL', 0, () => v('R') && `[ ${v('R')}.a, ${v('R')}.b ]`],
    ['LL', 0, () => v('LL') && `List.reverse ${v('LL')}`],
    ['LL', 0, () => v('LL') && `List.filter ${v('LL')} λz → List.length z > 0`],
    ['LL', 0, () => v('LL') && `List.map ${v('LL')} ${H}idL`],
  ];
  const steps = 6 + Math.floor(R() * 9);
  // Two seeds so that every type can be made.
  for (const s of [`[ n, 1 ]`, `List.range 0 n`]) {
    const name = `v${k++}`;
    lines.push(`${name} = ${s}`);
    env.L.push(name);
    bornAt[name] = lines.length - 1;
  }
  let guard = 0;
  let writes = 0;
  const maxWrites = 1 + Math.floor(R() * 2);
  while (lines.length < steps + 2 && guard++ < 400) {
    const [t, w, mk] = pickA(ops);
    if (w && (writes >= maxWrites || R() < 0.5)) continue;
    const before = { ...uses };
    const e = mk();
    if (!e) { Object.assign(uses, before); for (const x in uses) if (!(x in before)) delete uses[x]; continue; }
    refs.push([lines.length, e]);
    const name = `v${k++}`;
    lines.push(`${name} =${e.includes('\n') ? '\n' + ind(e, 4) : ' ' + e}`);
    env[t].push(name);
    bornAt[name] = lines.length - 1;
    if (w) { lastWrite = lines.length - 1; writes++; }
  }
  // What is printed: a random subset of the names, always the last one.
  const all = Object.values(env).flat();
  const shown = all.filter(() => R() < 0.2);
  const last = `v${k - 1}`;
  if (!shown.includes(last)) shown.push(last);
  const typeOf = (x) => Object.keys(env).find((t) => env[t].includes(x));
  const show = (x) => ({
    L: `${H}showL ${x}`, LL: `${H}showLL ${x}`, R: `${H}showL ${x}.a ++ "/" ++ ${H}showL ${x}.b`,
    P: `${H}showL (${H}fstP ${x}) ++ "/" ++ ${H}showL (${H}sndP ${x})`, M: `${H}showL (${H}fromM ${x})`,
    F: `${H}showL (${x} ⊤)`, B: `${H}showL (${H}items ${x})`,
    T: `${H}showL (${H}leftmost ${x}) ++ "/" ++ ${H}showL (${H}rightmost ${x})`, C: `${H}showL (${x}.get ⊤)`, W: `${H}showL ${x}.v`,
  })[typeOf(x)];
  const readAfter = (x) => shown.includes(x) || refs.some(([at, e]) => at > lastWrite && new RegExp(`\\b${x}\\b`).test(e));
  const live = all.some((x) => bornAt[x] < lastWrite && readAfter(x)) ? 'live' : 'dead';
  // Each name not shown is read by nothing: bind it with `_` would change nothing, so keep it.
  const body = [...lines, `String.join [ ${shown.sort().map(show).join(', ')} ] " "`].join('\n');
  const shows = `showL : List Int → String
showL l = "[" ++ String.join (List.map l String.fromInt) "," ++ "]"


showLL : List (List Int) → String
showLL ll = String.join (List.map ll showL) ";"
`;
  const typeR = 'pub type alias R =\n    { a : List Int, b : List Int }\n';
  const imports = 'import Dict\nimport List\nimport Maybe\nimport Ref\nimport String\n';
  const go = `go : Int → String\ngo n =\n${ind(body, 4)}\n`;
  const main = 'main : Program\nmain = Node.print (go 3)\n';
  const pubHelpers = (mod ? HELPERS.replace(/^([a-z][A-Za-z]* :)/gm, 'pub $1') : HELPERS);
  const showsP = mod ? shows.replace(/^([a-z][A-Za-z]* :)/gm, 'pub $1') : shows;
  if (mod) {
    return [live, {
      'H.beni': [imports, typeR, pubHelpers, showsP].join('\n\n'),
      'Main.beni': [`${imports}import H exposing (R)\nimport Node exposing (Program)\n`, go, main].join('\n\n'),
    }];
  }
  return [live, { 'Main.beni': [`${imports}import Node exposing (Program)\n`, typeR, HELPERS, shows, go, main].join('\n\n') }];
}

for (let i = FROM; i < FROM + RANDS; i++) {
  const [live, files] = makeRand(i);
  emit(`rand.${String(i).padStart(5, '0')}.${live}`, files);
}


// ---- alias ------------------------------------------------------------------------------------
//
// `alias.*`: one value of a type written with generic aliases, nested (`Box`, `Pair`, `Twin`,
// `Deep`, a row alias), read at one path and written at a path; decoy functions read the same
// aliases at other arguments first, so that a reading of an alias kept for one list of arguments
// would be read again for another (kernel §8, the adapter of `own2/Groups.zig`). `BLIND9H_ALIASES`
// programs, default 1500.

const ALIASES = Number(process.env.BLIND9H_ALIASES ?? 1500);
const ALIAS_DECLS = `type alias Box a =
    { item : a, n : Int }


type alias Pair a b =
    { fst : a, snd : b }


type alias Twin a =
    Pair a a


type alias Deep a =
    Box (Twin (Box a))


type alias Tri a b c =
    { one : a, two : Pair b c }


type alias Holds r =
    { r | held : List Int }
`;

function makeAlias(seed) {
  const R = rng(seed + 77);
  const pickA = (a) => a[Math.floor(R() * a.length)];
  let k = 0;
  // A type: { t: text, v: value expression, paths: [[path, isList]] }.
  function ty(depth) {
    const leaves = [
      () => ({ t: 'List Int', v: `[ ${k++}, ${k++} ]`, paths: [['', true]] }),
      () => ({ t: 'Int', v: `${k++}`, paths: [] }),
      () => ({ t: 'List (List Int)', v: `[ [ ${k++} ], [ ${k++} ] ]`, paths: [['', true]] }),
    ];
    if (depth <= 0 || R() < 0.2) return pickA(leaves)();
    const c = Math.floor(R() * 6);
    const a = ty(depth - 1);
    const par = (x) => (x.t.includes(' ') ? `(${x.t})` : x.t);
    if (c === 0) return { t: `Box ${par(a)}`, v: `{ item = ${a.v}, n = 1 }`, paths: a.paths.map(([q, l]) => ['.item' + q, l]) };
    if (c === 1) { const b = ty(depth - 1); return { t: `Pair ${par(a)} ${par(b)}`, v: `{ fst = ${a.v}, snd = ${b.v} }`, paths: [...a.paths.map(([q, l]) => ['.fst' + q, l]), ...b.paths.map(([q, l]) => ['.snd' + q, l])] }; }
    if (c === 2) { const b = { ...a, v: a.v.replace(/\d+/g, () => String(k++)) }; return { t: `Twin ${par(a)}`, v: `{ fst = ${a.v}, snd = ${b.v} }`, paths: [...a.paths.map(([q, l]) => ['.fst' + q, l]), ...a.paths.map(([q, l]) => ['.snd' + q, l])] }; }
    if (c === 3) {
      const v2 = a.v.replace(/\d+/g, () => String(k++));
      return { t: `Deep ${par(a)}`, v: `{ item = { fst = { item = ${a.v}, n = 1 }, snd = { item = ${v2}, n = 2 } }, n = 3 }`, paths: [...a.paths.map(([q, l]) => ['.item.fst.item' + q, l]), ...a.paths.map(([q, l]) => ['.item.snd.item' + q, l])] };
    }
    if (c === 4) { const b = ty(depth - 1); const d = ty(depth - 1); return { t: `Tri ${par(a)} ${par(b)} ${par(d)}`, v: `{ one = ${a.v}, two = { fst = ${b.v}, snd = ${d.v} } }`, paths: [...a.paths.map(([q, l]) => ['.one' + q, l]), ...b.paths.map(([q, l]) => ['.two.fst' + q, l]), ...d.paths.map(([q, l]) => ['.two.snd' + q, l])] }; }
    return { t: `Holds { tag : ${a.t} }`, v: `{ tag = ${a.v}, held = [ ${k++} ] }`, paths: [['.held', true], ...a.paths.map(([q, l]) => ['.tag' + q, l])] };
  }
  let main;
  for (let tries = 0; tries < 50; tries++) { main = ty(2 + Math.floor(R() * 3)); if (main.paths.length >= 2 && main.t.length < 160) break; }
  if (main.paths.length < 1) return null;
  const decoys = [];
  for (let i = 0; i < 3; i++) {
    const d = ty(2);
    decoys.push(`decoy${i} : ${d.t} → ${d.t}\ndecoy${i} x = x\n`);
  }
  const wp = pickA(main.paths);
  const same = R() < 0.5;
  const rp = same ? wp : pickA(main.paths);
  const kind = same || rp[0] === wp[0] || rp[0].startsWith(wp[0]) || wp[0].startsWith(rp[0]) ? 'live' : 'dead';
  const ll = (q) => q[1] && main.t && true;
  const isLL = (path) => {
    // Whether the list at the path is a list of lists: read off the value text is hard; use a tag in the leaf.
    return false;
  };
  const write = pickA([
    (x) => `List.push ${x} ${x}`,
    (x) => `List.set ${x} 0 (List.get ${x} 1 ▷ Maybe.withDefault ${x})`,
    (x) => `List.pop ${x}`,
    (x) => `List.swap ${x} 0 1`,
  ]);
  const showOf = (x) => `Debug.toString ${x}`;
  const body = [
    `v : ${main.t}`,
    `v = ${main.v}`,
    `old = v${rp[0]}`,
    `d0 = decoy0 (decoy0 ${decoys.length ? 'vd0' : ''})`,
  ];
  // The decoys are applied to values built by the decoy's own type.
  return { main, decoys, wp, rp, kind, write };
}

function aliasProgram(seed) {
  const R = rng(seed + 991);
  const a = makeAlias(seed);
  if (!a) return null;
  const { main, wp, rp, kind } = a;
  // The write: a list of the path's own type, written in a way that type-checks for both leaf kinds.
  const w = R() < 0.5 ? `List.pop v${wp[0]}` : `List.swap v${wp[0]} 0 1`;
  const via = Math.floor(R() * 5);
  const mod = R() < 0.5;
  const M = mod ? 'T.' : '';
  const v2 = main.v.replace(/\[ (\d+)/g, (_, d) => `[ ${Number(d) + 100}`);
  const lines = [`v : ${main.t}`, `v = ${main.v}`, `old = v${rp[0]}`];
  const onU = w.replace(/v\./g, 'u.');
  if (via === 0) lines.push(`w = ${w}`);
  else if (via === 1) lines.push(`w = ${M}idA (${w})`);
  else if (via === 2) lines.push(`u = ${M}idA v`, `w = ${onU}`);
  else if (via === 3) lines.push(`v2 : ${main.t}`, `v2 = ${v2}`, `u = ${M}chooseA (n > 1) v v2`, `w = ${onU}`);
  else lines.push(`v2 : ${main.t}`, `v2 = ${v2}`, `u = ${M}firstA (${M}pairA v v2)`, `w = ${onU}`);
  lines.push(kind === 'live' || R() < 0.5 ? `Debug.toString old ++ " " ++ Debug.toString w` : `Debug.toString w`);
  const shown = lines[lines.length - 1].includes('old') ? 'live' : 'dead';
  const tw = kind === 'live' && shown === 'live' ? 'live' : (shown === 'live' ? 'apart' : 'dead');
  const decoyText = a.decoys.join('\n\n');
  const gens = 'idA : a → a\nidA x = x\n\n\nchooseA : Bool, a, a → a\nchooseA b x y = if b then x else y\n\n\npairA : a, b → a × b\npairA x y = ( x, y )\n\n\nfirstA : a × b → a\nfirstA ( x, _ ) = x\n';
  const goText = `go : Int → String\ngo n =\n${ind(lines.join('\n'), 4)}\n`;
  if (mod) {
    const pubd = (t) => t.replace(/^type alias/gm, 'pub type alias').replace(/^([a-z][A-Za-z0-9]* :)/gm, 'pub $1');
    return [tw, {
      'T.beni': ['import List\n', pubd(ALIAS_DECLS), pubd(decoyText), pubd(gens)].join('\n\n'),
      'Main.beni': ['import Debug\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport T exposing (Box, Deep, Holds, Pair, Tri, Twin)\n', goText, 'main : Program\nmain = Node.print (go 3)\n'].join('\n\n'),
    }];
  }
  const src = [
    'import Debug\nimport List\nimport Maybe\nimport Node exposing (Program)\n',
    ALIAS_DECLS,
    decoyText,
    gens,
    goText,
    'main : Program\nmain = Node.print (go 3)\n',
  ].join('\n\n');
  return [tw, { 'Main.beni': src }];
}

for (let i = FROM; i < FROM + ALIASES; i++) {
  const r = aliasProgram(i);
  if (!r) continue;
  emit(`alias.${String(i).padStart(5, '0')}.${r[0]}`, r[1]);
}


// ---- tea --------------------------------------------------------------------------------------
//
// `tea.<saver>.<write>.<twin>`: a `browser-tea` page whose `update` writes `model.items` in place
// on `Add`, while `Save` keeps something made from `model.items` in `model.saved` by one of 24
// savers (a helper of a second module, a generic one, `List.take`, `List.drop`, a fold, a
// `Dict`, a `Maybe`, a record, a pair, a closure, the message). The steps press Save, then Add
// twice. `live` shows `saved` after the writes; `dead` shows only `items`.

const SAVERS = {
  direct: 'model.items',
  helper: 'H.keep model.items',
  generic: 'H.idA model.items',
  take: 'List.take model.items 100',
  drop0: 'List.drop model.items 0',
  dropk: '[ 0, …List.drop model.items 1 ]',
  spread: '[ …model.items ]',
  fold: 'List.foldl [ 1 ] model.items λ_ a → a',
  dict: 'Dict.get (Dict.insert Dict.empty 1 model.items) 1 ▷ Maybe.withDefault []',
  maybe: 'H.getOr (Just model.items) []',
  record: '(H.box model.items).item',
  pair: 'H.first ( model.items, 1 )',
  closure: '(H.later model.items) ⊤',
  choose: 'H.choose (model.n > 0) model.items []',
  rest: 'H.rest model.items',
  copy: 'List.copy model.items',
  map: 'List.map model.items λx → x',
  head: 'List.head [ model.items ] ▷ Maybe.withDefault []',
  nested: '(H.wrapTwice model.items).item.item',
  updated: '(H.setItem (H.box []) model.items).item',
  ref: 'H.viaRef model.items',
  fromInit: 'model.first',
  pairModel: 'H.first ( model, 1 ) ▷ .items',
  msg: 'xs',
};
const TEA_WRITES = { push: 'List.push model.items model.n', set: 'List.set model.items 0 model.n', pop: 'List.pop model.items' };
const teaHelpers = `import Dict
import List
import Maybe
import Ref


pub keep : List Int → List Int
pub keep l = l
`.replace('pub keep l = l', 'keep l = l') + `

pub idA : a → a
idA x = x


pub getOr : Maybe a, a → a
getOr m d =
    case m of
        Just x →
            x

        Nothing →
            d


pub box : a → { item : a }
box x = { item = x }


pub wrapTwice : a → { item : { item : a } }
wrapTwice x = { item = { item = x } }


pub setItem : { item : a }, a → { item : a }
setItem b x = { b | item = x }


pub first : a × b → a
first ( x, _ ) = x


pub later : a → (⊤ → a)
later x = λ⊤ → x


pub choose : Bool, a, a → a
choose b x y = if b then x else y


pub rest : List Int → List Int
rest l =
    case l of
        [ x, …r ] →
            [ x, …r ]

        [] →
            []


pub viaRef : a → a
viaRef x = Ref.get (Ref.make x)
`;
for (const [sv, se] of Object.entries(SAVERS)) for (const [wn, we] of Object.entries(TEA_WRITES)) for (const tw of ['live', 'dead']) {
  const saveArm = sv === 'msg' ? 'Save xs →\n    { model | saved = xs }' : `Save →\n    { model | saved = ${se} }`;
  const saveMsg = sv === 'msg' ? '{Save model.items}' : '{Save}';
  const msgType = sv === 'msg' ? 'Save (List Int)' : 'Save';
  const main = `import Dict
import H
import Html exposing (Html)
import List
import Maybe
import String
import Tea


type alias Model =
    items : List Int
    saved : List Int
    first : List Int
    n : Int


type Msg
    = Add
    | ${msgType}


update : Msg, Model → Model
update msg model =
    case msg of
        Add →
            { model | items = ${we}, n = model.n + 1 }

${ind(saveArm, 8)}


showL : List Int → String
showL l = String.join (List.map l String.fromInt) ","


view : Model → Html Msg
view model =
    <main>
        <button id="add" onClick={Add}>add</button>
        <button id="save" onClick=${saveMsg}>save</button>
        <p id="items">{showL model.items}</p>
${tw === 'live' ? '        <p id="saved">{showL model.saved}</p>\n' : ''}    </main>


main : Tea.Program
main =
    Tea.sandbox
        { init =
            λ⊤ →
                l = [ 1, 2 ]
                { items = l, saved = [], first = ${sv === 'fromInit' ? 'l' : '[]'}, n = 3 }
        , update = update
        , view = view
        }
`;
  emit(`tea.${sv}.${wn}.${tw}`, { 'Main.beni': main, 'H.beni': teaHelpers, PLATFORM: 'platforms/browser-tea\n', steps: 'click #save\nclick #add\nclick #add\n' });
}


// ---- hand ------------------------------------------------------------------------------------
//
// `hand.*`: the hand-written probes of research report 132, each a whole program (its files below).
const HAND = {
 "hand.eq.derived.live": {"Main.beni":"import List\nimport Node exposing (Program)\nimport String\nimport W exposing (W)\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    r = { w = W.W xs, n = 1 }\n    s = { w = W.W [ 1, 2 ], n = 1 }\n    same = r == s\n    (if same then \"same \" else \"other \") ++ showL xs ++ \" \" ++ showL (W.items r.w)\n\n\nmain : Program\nmain = Node.print (go 3)\n","W.beni":"import List\n\n\npub type W\n    = W (List Int)\n\n\npub eq : W, W → Bool\neq (W a) (W b) = List.length (List.push a 1) == List.length b\n\n\npub items : W → List Int\nitems (W a) = a\n"},
 "hand.via.writer.live": {"Main.beni":"import List\nimport Node exposing (Program)\nimport Schema exposing (Conversion)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nback : List Int → Result (List Schema.Issue) (List Int)\nback l = Ok (List.push l 9)\n\n\nconv : Conversion (List Int) (List Int)\nconv = Schema.conversion (λl → Ok l) back\n\n\nschema Box =\n    items : List Int via conv\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    out =\n        case Box.print { items = xs } of\n            Ok t →\n                t\n\n            Err _ →\n                \"err\"\n    out ++ \" \" ++ showL xs\n\n\nmain : Program\nmain = Node.print (go 3)\n"},
 "hand.via.lambda.live": {"Main.beni":"import List\nimport Node exposing (Program)\nimport Schema exposing (Conversion)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nback : List Int → Result (List Schema.Issue) (List Int)\nback l = Ok (List.push l 9)\n\n\nconv : Conversion (List Int) (List Int)\nconv = Schema.conversion (λl → Ok l) (λl → Ok (List.push l 9))\n\n\nschema Box =\n    items : List Int via conv\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    out =\n        case Box.print { items = xs } of\n            Ok t →\n                t\n\n            Err _ →\n                \"err\"\n    out ++ \" \" ++ showL xs\n\n\nmain : Program\nmain = Node.print (go 3)\n"},
 "hand.schemactor.call.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    ev = Ev.Put { xs = l }\n    out =\n        case ev of\n            Ev.Put p →\n                showL (List.push p.xs 9)\n\n            Ev.Tick _ →\n                \"t\"\n    out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.call.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    ev = Ev.Put { xs = l }\n    out =\n        case ev of\n            Ev.Put p →\n                showL (List.push p.xs 9)\n\n            Ev.Tick _ →\n                \"t\"\n    showL l ++ \" \" ++ out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.map.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    es = List.map [ { xs = l } ] Ev.Put\n    out =\n        case es of\n            [ Ev.Put p, …_ ] →\n                showL (List.push p.xs 9)\n\n            _ →\n                \"t\"\n    out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.map.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    es = List.map [ { xs = l } ] Ev.Put\n    out =\n        case es of\n            [ Ev.Put p, …_ ] →\n                showL (List.push p.xs 9)\n\n            _ →\n                \"t\"\n    showL l ++ \" \" ++ out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.partial.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    mk = Ev.Put _\n    ev = mk { xs = l }\n    out =\n        case ev of\n            Ev.Put p →\n                showL (List.push p.xs 9)\n\n            Ev.Tick _ →\n                \"t\"\n    out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.partial.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    mk = Ev.Put _\n    ev = mk { xs = l }\n    out =\n        case ev of\n            Ev.Put p →\n                showL (List.push p.xs 9)\n\n            Ev.Tick _ →\n                \"t\"\n    showL l ++ \" \" ++ out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.print.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    s = Ev.print (Ev.Put { xs = l })\n    l2 = List.push l 5\n    out =\n        case s of\n            Ok t →\n                t ++ showL l2\n\n            Err _ →\n                \"e\"\n    out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.print.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    s = Ev.print (Ev.Put { xs = l })\n    l2 = List.push l 5\n    out =\n        case s of\n            Ok t →\n                t ++ showL l2\n\n            Err _ →\n                \"e\"\n    showL l ++ \" \" ++ out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.value.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\napply : (a → b), a → b\napply f x = f x\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    ev = apply Ev.Put { xs = l }\n    out =\n        case ev of\n            Ev.Put p →\n                showL (List.push p.xs 9)\n\n            Ev.Tick _ →\n                \"t\"\n    out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.schemactor.value.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\nimport Schema\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nschema Ev tagged \"kind\" of\n    Put as \"put\"\n        xs : List Int\n    Tick as \"tick\"\n        n : Int\n\n\napply : (a → b), a → b\napply f x = f x\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    ev = apply Ev.Put { xs = l }\n    out =\n        case ev of\n            Ev.Put p →\n                showL (List.push p.xs 9)\n\n            Ev.Tick _ →\n                \"t\"\n    showL l ++ \" \" ++ out\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.alt.update.dead": {
  "Main.beni": "import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    xs = [ [ n ], [ 2 ] ]\n    b = List.get xs 1 ▷ Maybe.withDefault []\n    ys = List.update xs 0 λ_ → List.copy b\n    zs = List.update ys 0 λl → List.push l 9\n    showLL zs\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.alt.update.live": {
  "Main.beni": "import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    xs = [ [ n ], [ 2 ] ]\n    b = List.get xs 1 ▷ Maybe.withDefault []\n    ys = List.update xs 0 λ_ → b\n    zs = List.update ys 0 λl → List.push l 9\n    showLL zs\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.alt.updatepat.live": {
  "Main.beni": "import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    xs = [ [ n ], [ 2 ] ]\n    ys =\n        case xs of\n            [ _, b ] →\n                List.update xs 0 λ_ → b\n\n            _ →\n                xs\n    zs = List.update ys 1 λl → List.push l 9\n    showLL zs\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.append.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = [ shared ] ++ [ shared ]\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.concatmap.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.concatMap [ 1, 2 ] λ_ → [ shared ]\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.dictfold.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = Dict.foldl (Dict.fromList [ ( 1, 1 ), ( 2, 2 ) ]) [] λ_ _ acc → List.push acc shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.dictmap.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = Dict.values (Dict.map (Dict.fromList [ ( 1, [] ), ( 2, [] ) ]) λ_ _ → shared)\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.dictvals.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = Dict.values (Dict.insert (Dict.insert Dict.empty 1 shared) 2 shared)\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.filtermap.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.filterMap [ 1, 2 ] λ_ → Just shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.foldpush.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.foldl [ 1, 2 ] [] λ_ acc → List.push acc shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.foldr.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.foldr [ 1, 2 ] [] λ_ acc → List.push acc shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.indexed.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.indexedMap [ 1, 2 ] λ_ _ → shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.init.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.initialize 2 λ_ → shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.map.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.map [ 1, 2 ] λ_ → shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.range.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.map (List.range 1 2) λ_ → shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.repeat.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.repeat shared 2\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.reverse.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.reverse [ shared, shared ]\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.sort.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.sortBy [ shared, shared ] List.length\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dup.zip.live": {
  "Main.beni": "import List\nimport Maybe\nimport Dict\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\ngo : Int → String\ngo n =\n    shared = [ n ]\n    ll = List.map2 [ 1, 2 ] [ 3, 4 ] λ_ _ → shared\n    ll2 = List.update ll 0 λl → List.push l 9\n    showLL ll2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain10.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    f10 = λ⊤ → f9 ⊤\n    r = f10 ⊤\n    w = List.push (List.copy xs) 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain10.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    f10 = λ⊤ → f9 ⊤\n    r = f10 ⊤\n    w = List.push xs 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain13.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    f10 = λ⊤ → f9 ⊤\n    f11 = λ⊤ → f10 ⊤\n    f12 = λ⊤ → f11 ⊤\n    f13 = λ⊤ → f12 ⊤\n    r = f13 ⊤\n    w = List.push (List.copy xs) 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain13.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    f10 = λ⊤ → f9 ⊤\n    f11 = λ⊤ → f10 ⊤\n    f12 = λ⊤ → f11 ⊤\n    f13 = λ⊤ → f12 ⊤\n    r = f13 ⊤\n    w = List.push xs 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain20.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    f10 = λ⊤ → f9 ⊤\n    f11 = λ⊤ → f10 ⊤\n    f12 = λ⊤ → f11 ⊤\n    f13 = λ⊤ → f12 ⊤\n    f14 = λ⊤ → f13 ⊤\n    f15 = λ⊤ → f14 ⊤\n    f16 = λ⊤ → f15 ⊤\n    f17 = λ⊤ → f16 ⊤\n    f18 = λ⊤ → f17 ⊤\n    f19 = λ⊤ → f18 ⊤\n    f20 = λ⊤ → f19 ⊤\n    r = f20 ⊤\n    w = List.push (List.copy xs) 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain20.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    f10 = λ⊤ → f9 ⊤\n    f11 = λ⊤ → f10 ⊤\n    f12 = λ⊤ → f11 ⊤\n    f13 = λ⊤ → f12 ⊤\n    f14 = λ⊤ → f13 ⊤\n    f15 = λ⊤ → f14 ⊤\n    f16 = λ⊤ → f15 ⊤\n    f17 = λ⊤ → f16 ⊤\n    f18 = λ⊤ → f17 ⊤\n    f19 = λ⊤ → f18 ⊤\n    f20 = λ⊤ → f19 ⊤\n    r = f20 ⊤\n    w = List.push xs 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain4.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    r = f4 ⊤\n    w = List.push (List.copy xs) 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain4.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    r = f4 ⊤\n    w = List.push xs 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain8.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    r = f8 ⊤\n    w = List.push (List.copy xs) 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain8.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    r = f8 ⊤\n    w = List.push xs 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain9.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    r = f9 ⊤\n    w = List.push (List.copy xs) 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ans.chain9.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    f0 = λ⊤ → xs\n    f1 = λ⊤ → f0 ⊤\n    f2 = λ⊤ → f1 ⊤\n    f3 = λ⊤ → f2 ⊤\n    f4 = λ⊤ → f3 ⊤\n    f5 = λ⊤ → f4 ⊤\n    f6 = λ⊤ → f5 ⊤\n    f7 = λ⊤ → f6 ⊤\n    f8 = λ⊤ → f7 ⊤\n    f9 = λ⊤ → f8 ⊤\n    r = f9 ⊤\n    w = List.push xs 1\n    showL r ++ \" \" ++ showL w\n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ref.fnarg.live": {
  "Main.beni": "import List\nimport Ref exposing (Ref)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nbump : Ref (List Int) → ⊤\nbump r = Ref.update r λl → List.push l 9\n\n\ngo : Int → String\ngo n =\n    r = Ref.make [ n ]\n    old = Ref.get r\n    bump r\n    showL old ++ \" \" ++ showL (Ref.get r)\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ref.modold.live": {
  "Main.beni": "import List\nimport Ref exposing (Ref)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    r = Ref.make [ n ]\n    old = Ref.get r\n    k = Ref.modify r λl → ( 1, List.push l 9 )\n    showL old ++ \" \" ++ showL (Ref.get r) ++ String.fromInt k\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ref.setget.live": {
  "Main.beni": "import List\nimport Ref exposing (Ref)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    r = Ref.make []\n    ys = [ n ]\n    Ref.set r ys\n    Ref.update r λl → List.push l 9\n    showL ys ++ \" \" ++ showL (Ref.get r)\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ref.twoRefs.live": {
  "Main.beni": "import List\nimport Ref exposing (Ref)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    xs = [ n ]\n    r = Ref.make xs\n    s = Ref.make (Ref.get r)\n    Ref.update r λl → List.push l 9\n    showL (Ref.get s) ++ \" \" ++ showL (Ref.get r)\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ref.updold.dead": {
  "Main.beni": "import List\nimport Ref exposing (Ref)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    r = Ref.make [ n ]\n    Ref.update r λl → List.push l 9\n    showL (Ref.get r)\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.ref.updold.live": {
  "Main.beni": "import List\nimport Ref exposing (Ref)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    r = Ref.make [ n ]\n    old = Ref.get r\n    Ref.update r λl → List.push l 9\n    showL old ++ \" \" ++ showL (Ref.get r)\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.cov.constlocal.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\ntable : List (Int → Int)\ntable =\n    unused : Int → Int\n    unused j = j * 2\n    [ λx → x + 1 ]\n\n\nmain : Program\nmain = Node.print (String.fromInt (List.length table))\n"
 },
 "hand.cov.deadarm.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\ngo : Int → String\ngo n =\n    case [ n ] of\n        [] →\n            g = λk → k + n\n            String.fromInt (g 1)\n\n        [ x, …_ ] →\n            String.fromInt x\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.cov.localinlambda.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\ngo : Int → String\ngo n =\n    f = λk →\n        inner : Int → Int\n        inner j = j + k\n        k\n    String.fromInt (f n)\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.cov.recunused.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\ngo : Int → String\ngo n =\n    loop : Int, List Int → List Int\n    loop k acc =\n        if k ≤ 0 then\n            acc\n        else\n            loop (k - 1) (List.push acc k)\n    String.fromInt n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.cov.shadowfnarg.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\napply : (Int → Int), Int → Int\napply f x = f x\n\n\ngo : Int → String\ngo n =\n    r =\n        apply\n            (λk →\n                h : Int → Int\n                h j = j + k\n                k\n            )\n            n\n    String.fromInt r\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.cov.typedispatch.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\npub type Bag\n    = Bag (List Int)\n\n\npub empty : ⊤ → Bag\nempty ⊤ = Bag []\n\n\npub size : Bag → Int\nsize (Bag l) = List.length l\n\n\nmake : ⊤ → a\n    where a.empty : ⊤ → a\nmake ⊤ = a.empty ⊤\n\n\nmain : Program\nmain =\n    b : Bag\n    b = make ⊤\n    Node.print (String.fromInt b.size)\n"
 },
 "hand.cov.unusedlambda.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\ngo : Int → String\ngo n =\n    _ = λk → List.push [ k ] n\n    f = λk → List.length [ k, n ]\n    String.fromInt n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.cov.unusedlocalfn.dead": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\ngo : Int → String\ngo n =\n    helper : Int → List Int\n    helper k = List.push [ k ] n\n    other : Int → List Int\n    other k = helper (k + 1)\n    String.fromInt n\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.task.foreach.dead": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    out = Task.forEach [ [ 1 ], [ 2 ] ] 2 λl →\n        Io.sleep 1\n        List.push l 9\n    Node.print (showLL out)\n"
 },
 "hand.task.foreachdup.live": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    a = [ 1 ]\n    out = Task.forEach [ a, a ] 2 λl →\n        Io.sleep 1\n        List.push l 9\n    Node.print (showLL out)\n"
 },
 "hand.task.foreachkeep.live": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    ll = [ [ 1 ], [ 2 ] ]\n    out = Task.forEach ll 2 λl →\n        Io.sleep 1\n        List.push l 9\n    Node.print (showLL out ++ \" \" ++ showLL ll)\n"
 },
 "hand.task.par.live": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nwork : List Int → List Int\nwork l =\n    Io.sleep 3\n    List.push l 9\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    xs = [ 1 ]\n    ( p, q ) = Task.par (λ⊤ → work xs) (λ⊤ → showL xs)\n    Node.print (showL p ++ \" \" ++ q)\n"
 },
 "hand.task.parfresh.dead": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nwork : List Int → List Int\nwork l =\n    Io.sleep 3\n    List.push l 9\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    ( p, q ) = Task.par (λ⊤ → work [ 1 ]) (λ⊤ → work [ 2 ])\n    Node.print (showL p ++ \" \" ++ showL q)\n"
 },
 "hand.task.scope.live": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    xs = [ 1 ]\n    r = Task.scope λs →\n        f = Task.spawnIn s λ⊤ →\n            Io.sleep 2\n            List.length xs\n        Task.join f\n    w = List.push xs 5\n    Node.print (String.fromInt r ++ \" \" ++ showL w)\n"
 },
 "hand.task.sleepwrite.live": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nwork : List Int → List Int\nwork l =\n    Io.sleep 3\n    List.push l 9\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    xs = [ 1 ]\n    f = Task.spawn λ⊤ → work (List.copy xs)\n    ys = work xs\n    Node.print (showL ys ++ \" \" ++ showL (Task.join f) ++ \" \" ++ showL xs)\n"
 },
 "hand.task.spawncap.live": {
  "Main.beni": "import Io\nimport List\nimport Node exposing (Program)\nimport String\nimport Task\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nshowLL : List (List Int) → String\nshowLL ll = String.join (List.map ll showL) \";\"\n\n\nmain : Program\nmain = Io.run λ⊤ →\n    xs = [ 1, 2 ]\n    f = Task.spawn λ⊤ →\n        Io.sleep 5\n        showL xs\n    w = List.push xs 3\n    Node.print (Task.join f ++ \" \" ++ showL w)\n"
 },
 "hand.prepend.reuse.live": {
  "Main.beni": "import List\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    l = List.range 1 n\n    rest = List.drop l 1\n    m = [ 1, …rest ]\n    m2 = List.push m 9\n    showL l ++ \" \" ++ showL m2\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dictupdate.precision.dead": {
  "Main.beni": "import List\nimport Maybe\nimport Dict exposing (Dict)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\ngo : Int → String\ngo n =\n    d = Dict.insert Dict.empty 1 [ n ]\n    d2 = Dict.update d 1 λm → Maybe.map m λz → List.push z 3\n    showL (Dict.get d2 1 ▷ Maybe.withDefault [])\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 },
 "hand.dictupdate2.precision.dead": {
  "Main.beni": "import List\nimport Maybe\nimport Dict exposing (Dict)\nimport Node exposing (Program)\nimport String\n\n\nshowL : List Int → String\nshowL l = String.join (List.map l String.fromInt) \",\"\n\n\nadd : Dict Int (List Int), Int, Int → Dict Int (List Int)\nadd d k x =\n    Dict.update d k λm →\n        case m of\n            Just z →\n                Just (List.push z x)\n\n            Nothing →\n                Just [ x ]\n\n\ngo : Int → String\ngo n =\n    d = add (add (add Dict.empty 1 n) 1 4) 2 5\n    showL (Dict.get d 1 ▷ Maybe.withDefault [])\n\n\nmain : Program\nmain = Node.print (go 3)\n"
 }
};
for (const [name, files] of Object.entries(HAND)) emit(name, files);

fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
