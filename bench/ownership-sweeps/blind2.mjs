// blind2.mjs <outdir> [filter]: a generator for research report 114, a second blind test of the prototype
// (`--ownership=v3`). It covers first-order values: one list `q` at two places of a value, made in several ways,
// taken apart in several ways, and then one place written in place and the other read.
//
// Five families, one program per directory `<outdir>/<family>.<…>.<twin>/Main.beni`, and `<outdir>/LIST`:
//
// - `two`: shape × maker × use. A shape is a type with two list places (a tuple, a record, a constructor, a record
//   alias's constructor, the same constructor as a function value, a generic constructor, a list, a nested
//   tuple, a `Maybe` pair, a join, a record update, and five recursive types where the two places are an outer
//   part and an inner part). The maker puts `q` at both places: in the frame, in a callee that makes `q`
//   itself, in a callee that is handed `q` one or two times, one function further, through a generic identity,
//   through a tuple or a constructor that is taken apart again, in one arm of two, in a recursive function, in
//   a lambda run at once, in a local function, or through `?`. The use writes the first place and reads the
//   second (`ab`), or the other way (`ba`), or reads nothing after the write (`dead`).
// - `order`: an operand that reads `q` and a callee or a receiver that writes `q`, in a pipe `x ▷ e`. The
//   operand is written before the callee, but JavaScript evaluates the callee first. The `dead` twin reads
//   another list.
// - `deep`: one list at two places of the deep level of a recursive value (every place past the first trip
//   round the cycle), through four recursive types, six makers, and a use in `go` or in a callee.
// - `hof`: a function of `core/` that hands a callback the elements of a container, and a callback that writes
//   the element in place. The `live` twin reads the container after the call.
// - `result`: a function of `core/` whose answer is made from `q` (a copy, a view, `q` itself), for lists of
//   0, 1 and 2 elements. The answer is written in place; the `live` twin reads `q` after.
//
// A `live` twin (`ab`, `ba`, `live`) must be refused or print the plain build's output. A `dead` twin is safe.
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind2.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const L = 'List Int';
const HEAD = 'import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n';
const SHOW = `show : ${L} → String\nshow l =\n    String.join (List.map l String.fromInt) ","\n`;
const MAIN = 'main : Program\nmain =\n    Node.print (go 0)\n';
const program = (parts) => [HEAD, SHOW, ...parts.filter(Boolean), MAIN].join('\n\n');

// ---- family `two` -------------------------------------------------------------------------------------------

// A shape: its declarations, its type `T`, how to make it from two list expressions, and how to take it apart
// into `a` and `b` around the lines `k` (a function of `r`, the value).
const take = (pat, k) => `case r of\n    ${pat} →\n${ind(k, 8)}\n\n    _ →\n        "-"`;
const SHAPES = {
  tup: { T: `${L} × ${L}`, mk: (x, y) => `( ${x}, ${y} )`, parts: (k) => `a = r.0\nb = r.1\n${k}` },
  tupPat: { T: `${L} × ${L}`, mk: (x, y) => `( ${x}, ${y} )`, parts: (k) => `( a, b ) = r\n${k}` },
  rec: { T: `{ a : ${L}, b : ${L} }`, mk: (x, y) => `{ a = ${x}, b = ${y} }`, parts: (k) => `a = r.a\nb = r.b\n${k}` },
  recPat: { T: `{ a : ${L}, b : ${L} }`, mk: (x, y) => `{ a = ${x}, b = ${y} }`, parts: (k) => `{ a, b } = r\n${k}` },
  ctor: { decls: `type P\n    = P (${L}) (${L})\n`, T: 'P', mk: (x, y) => `P ${x} ${y}`, parts: (k) => `case r of\n    P a b →\n${ind(k, 8)}` },
  alias: { decls: `type alias B =\n    { a : ${L}, b : ${L} }\n`, T: 'B', mk: (x, y) => `B ${x} ${y}`, parts: (k) => `a = r.a\nb = r.b\n${k}` },
  aliasFn: { decls: `type alias B =\n    { a : ${L}, b : ${L} }\n`, T: 'B', mk: (x, y) => `(Maybe.withDefault (Maybe.map (Just ${x}) (λz → B z ${y})) (B [] []))`,
    parts: (k) => `a = r.a\nb = r.b\n${k}` },
  generic: { decls: 'type Two a\n    = Two a a\n', T: `Two (${L})`, mk: (x, y) => `Two ${x} ${y}`, parts: (k) => `case r of\n    Two a b →\n${ind(k, 8)}` },
  list: { T: `List (${L})`, mk: (x, y) => `[ ${x}, ${y} ]`, parts: (k) => take('[ a, b ]', k) },
  listGet: { T: `List (${L})`, mk: (x, y) => `[ ${x}, ${y} ]`,
    parts: (k) => `a = Maybe.withDefault (List.get r 0) []\nb = Maybe.withDefault (List.get r 1) []\n${k}` },
  nest: { T: `(${L} × Int) × ${L}`, mk: (x, y) => `( ( ${x}, 1 ), ${y} )`, parts: (k) => `a = r.0.0\nb = r.1\n${k}` },
  maybe: { T: `Maybe (${L}) × ${L}`, mk: (x, y) => `( Just ${x}, ${y} )`, parts: (k) => `b = r.1\n${take('Just a', k).replace('case r of', 'case r.0 of')}` },
  join: { T: `${L} × ${L}`, mk: (x, y) => `(if List.length ${x} ≥ 0 then ( ${x}, ${y} ) else ( [ 1 ], [ 2 ] ))`, parts: (k) => `a = r.0\nb = r.1\n${k}` },
  update: { T: `{ a : ${L}, b : ${L} }`, pre: (x) => `base = { a = ${x}, b = [ 5 ] }`, mk: (x, y) => `{ base | b = ${y} }`, parts: (k) => `a = r.a\nb = r.b\n${k}` },
  // Recursive types: the first place is at the entry level and the second at the deep level, or both deep.
  lstEntry: { decls: `type Lst\n    = Cons (${L}) Lst\n    | Nil\n`, T: 'Lst', mk: (x, y) => `Cons ${x} (Cons ${y} Nil)`, parts: (k) => take('Cons a (Cons b _)', k) },
  lstDeep: { decls: `type Lst\n    = Cons (${L}) Lst\n    | Nil\n`, T: 'Lst', mk: (x, y) => `Cons [ 0 ] (Cons ${x} (Cons ${y} Nil))`,
    parts: (k) => take('Cons _ (Cons a (Cons b _))', k) },
  tree: { decls: `type Tree\n    = Tree (${L}) (List Tree)\n`, T: 'Tree', mk: (x, y) => `Tree [ 0 ] [ Tree ${x} [ Tree ${y} [] ] ]`,
    parts: (k) => `case r of\n    Tree _ [ Tree a [ Tree b _ ] ] →\n${ind(k, 8)}\n\n    _ →\n        "-"` },
  recCycle: { decls: `type N\n    = N { xs : ${L}, next : Maybe N }\n`, T: 'N',
    mk: (x, y) => `N { xs = [ 0 ], next = Just (N { xs = ${x}, next = Just (N { xs = ${y}, next = Nothing }) }) }`,
    parts: (k) => `case r of\n    N { next } →\n        case next of\n            Just (N n1) →\n                case n1.next of\n                    Just (N n2) →\n                        a = n1.xs\n                        b = n2.xs\n${ind(k, 24)}\n\n                    Nothing →\n                        "-"\n\n            Nothing →\n                "-"` },
  genRec: { decls: 'type G a\n    = GC a (G a)\n    | GN\n', T: `G (${L})`, mk: (x, y) => `GC [ 0 ] (GC ${x} (GC ${y} GN))`, parts: (k) => take('GC _ (GC a (GC b _))', k) },
};

// A maker: the functions it needs and the lines of `go` that bind `r` (and `q` when `go` makes it). `mk(S, x, y,
// to)`: the lines that make the shape from `x` and `y`, the last one prefixed by `to`.
const mk = (S, x, y, to) => `${S.pre ? S.pre(x) + '\n' : ''}${to}${S.mk(x, y)}`;
const fn1 = (sig, head, body) => `${sig}\n${head} =\n${ind(body, 4)}\n`;
const MAKERS = {
  local: (S) => ({ go: `q = [ n, 2 ]\n${mk(S, 'q', 'q', 'r = ')}` }),
  fresh: (S) => ({ fns: fn1(`make : Int → ${S.T}`, 'make n', `q = [ n, 2 ]\n${mk(S, 'q', 'q', '')}`), go: 'r = make n' }),
  param: (S) => ({ fns: fn1(`make : ${L} → ${S.T}`, 'make q', mk(S, 'q', 'q', '')), go: 'q = [ n, 2 ]\nr = make q' }),
  params: (S) => ({ fns: fn1(`make : ${L}, ${L} → ${S.T}`, 'make x y', mk(S, 'x', 'y', '')), go: 'q = [ n, 2 ]\nr = make q q' }),
  further: (S) => ({ fns: fn1(`make : Int → ${S.T}`, 'make n', `q = [ n, 2 ]\n${mk(S, 'q', 'q', '')}`) + '\n\n' + fn1(`make2 : Int → ${S.T}`, 'make2 n', 'make n'), go: 'r = make2 n' }),
  ident: (S) => ({ fns: fn1('idt : a → a', 'idt x', 'x') + '\n\n' + fn1(`make : Int → ${S.T}`, 'make n', `q = [ n, 2 ]\n${mk(S, 'q', 'q', 'v = ')}\nidt v`), go: 'r = make n' }),
  boxed: (S) => ({ fns: fn1(`make : Int → (${S.T}) × Int`, 'make n', `q = [ n, 2 ]\n${mk(S, 'q', 'q', 'v = ')}\n( v, 1 )`), go: 'r = (make n).0' }),
  freshArg: (S) => ({ fns: fn1(`make : ${L} → ${S.T}`, 'make q', mk(S, 'q', 'q', '')), go: 'r = make [ n, 2 ]' }),
  // One of two arms; a recursive maker; a lambda run at once; a local function; `?`; a wrapper taken off again.
  arms: (S) => ({ fns: fn1(`make : Int → ${S.T}`, 'make n', `q = [ n, 2 ]\ncase n of\n    7 →\n${ind(mk(S, '[ 1 ]', '[ 2 ]', ''), 8)}\n\n    _ →\n${ind(mk(S, 'q', 'q', ''), 8)}`), go: 'r = make n' }),
  recur: (S) => ({ fns: fn1(`make : Int, Int → ${S.T}`, 'make k n', `if k == 0 then\n    q = [ n, 2 ]\n${ind(mk(S, 'q', 'q', ''), 4)}\n\nelse\n    make (k - 1) n`), go: 'r = make 3 n' }),
  lambda: (S) => ({ go: `q = [ n, 2 ]\nr = (λ⊤ →\n        ${mk(S, 'q', 'q', '').split('\n').join('\n        ')}\n    )\n        ⊤` }),
  localFn: (S) => ({ go: `q = [ n, 2 ]\nmk2 k =\n${ind(mk(S, 'q', 'q', ''), 4)}\nr = mk2 1` }),
  tried: (S) => ({ fns: fn1(`make : Int → Maybe (${S.T})`, 'make n', `q = [ n, 2 ]\n${mk(S, 'q', 'q', 'v = ')}\nJust v`) + '\n\n' + fn1(`make2 : Int → Maybe (${S.T})`, 'make2 n', 'v = (make n)?\nJust v'),
    go: `case make2 n of\n    Just r →\n        __K__\n\n    Nothing →\n        "-"` }),
  wrapped: (S) => ({ fns: `type Box\n    = Box (${S.T})\n\n\n` + fn1(`make : Int → Box`, 'make n', `q = [ n, 2 ]\n${mk(S, 'q', 'q', 'v = ')}\nBox v`), go: 'r =\n    case make n of\n        Box v →\n            v' }),
};

const USES = {
  ab: 'w = List.set a 0 9\nshow w ++ "/" ++ show b',
  ba: 'w = List.set b 0 9\nshow w ++ "/" ++ show a',
  dead: 'w = List.set a 0 9\nshow w',
};

function genTwo(sname, mname, uname) {
  const S = SHAPES[sname];
  const M = MAKERS[mname](S);
  // A maker can bind `r` in a `case` arm: the rest goes at `__K__`.
  const rest = S.parts(USES[uname]);
  const lines = M.go.includes('__K__') ? M.go.replace('__K__', ind(rest, 8).trimStart()) : `${M.go}\n${rest}`;
  return program([S.decls, M.fns, `go : Int → String\ngo n =\n${ind(lines, 4)}\n`]);
}

// ---- family `order` -----------------------------------------------------------------------------------------

// The callee or receiver that writes `q`: written after the operand, evaluated before it.
const CALLEES = {
  field: { fns: `mk : ${L} → { f : String → String }\nmk w =\n    { f = λs → s ++ "/" ++ show w }\n`, e: (W) => `(mk ${W}).f` },
  ifc: { fns: `mk : ${L} → (String → String)\nmk w =\n    λs → s ++ "/" ++ show w\n`, e: (W) => `(if n == 0 then mk ${W} else mk [])` },
  casec: { fns: `mk : ${L} → (String → String)\nmk w =\n    λs → s ++ "/" ++ show w\n`, e: (W) => `(case n of\n            0 →\n                mk ${W}\n\n            _ →\n                mk []\n        )` },
  tuplec: { fns: `mk : ${L} → (String → String) × Int\nmk w =\n    ( λs → s ++ "/" ++ show w, 1 )\n`, e: (W) => `(mk ${W}).0` },
  method: { method: true, e: (W) => `${W}.append` },
};
const WRITES = { set: '(List.set q 0 9)', push: '(List.push q 9)' };
const READS = { show: (x) => `show ${x}`, get: (x) => `String.fromInt (Maybe.withDefault (List.get ${x} 0) 7)`, len: (x) => `String.fromInt (List.length ${x})` };

function genOrder(cname, wname, rname, twin) {
  const C = CALLEES[cname];
  const src = twin === 'dead' ? '[ 4 ]' : 'q';
  let body;
  if (C.method) body = `show ([ ${rname === 'get' ? `Maybe.withDefault (List.get ${src} 0) 7` : `List.length ${src}`} ] ▷ ${C.e(WRITES[wname])})`;
  else body = `${READS[rname](src)} ▷ ${C.e(WRITES[wname])}`;
  return program([C.fns, `go : Int → String\ngo n =\n    q = [ n, 2 ]\n    ${body}\n`]);
}

// ---- family `deep` ------------------------------------------------------------------------------------------

// One list at two places of the deep level. `mk(q)` puts `q` at two deep places; `rep` is a recursive function
// that puts its parameter in every node. The maker is a callee that makes the value (`lit`, `rep`, `repFresh`,
// `further`), or `go` makes it itself (`built`, `builtRep`). The use is in `go` (`here`) or in a callee `f`
// that is handed the value (`callee`).
const DEEP = {
  lst: { decls: `type Lst\n    = Cons (${L}) Lst\n    | Nil\n`, T: 'Lst', mk: (q) => `Cons [ 0 ] (Cons ${q} (Cons ${q} Nil))`,
    rep: `rep : Int, ${L} → Lst\nrep k x =\n    if k == 0 then\n        Nil\n\n    else\n        Cons x (rep (k - 1) x)\n`,
    viaRep: (q) => `Cons [ 0 ] (rep 3 ${q})`, pat: 'Cons _ (Cons a (Cons b _))' },
  tree: { decls: `type Tree\n    = Tree (${L}) (List Tree)\n`, T: 'Tree', mk: (q) => `Tree [ 0 ] [ Tree ${q} [ Tree ${q} [] ] ]`,
    rep: `rep : Int, ${L} → Tree\nrep k x =\n    if k == 0 then\n        Tree x []\n\n    else\n        Tree x [ rep (k - 1) x ]\n`,
    viaRep: (q) => `Tree [ 0 ] [ rep 3 ${q} ]`, pat: 'Tree _ [ Tree a [ Tree b _ ] ]' },
  gen: { decls: 'type G a\n    = GC a (G a)\n    | GN\n', T: `G (${L})`, mk: (q) => `GC [ 0 ] (GC ${q} (GC ${q} GN))`,
    rep: `rep : Int, a → G a\nrep k x =\n    if k == 0 then\n        GN\n\n    else\n        GC x (rep (k - 1) x)\n`,
    viaRep: (q) => `GC [ 0 ] (rep 3 ${q})`, pat: 'GC _ (GC a (GC b _))' },
  pair: { decls: `type Pr\n    = Pr (${L}) (Pr × Int)\n    | End\n`, T: 'Pr', mk: (q) => `Pr [ 0 ] ( Pr ${q} ( Pr ${q} ( End, 0 ), 0 ), 0 )`,
    rep: `rep : Int, ${L} → Pr\nrep k x =\n    if k == 0 then\n        End\n\n    else\n        Pr x ( rep (k - 1) x, k )\n`,
    viaRep: (q) => `Pr [ 0 ] ( rep 3 ${q}, 0 )`, pat: 'Pr _ ( Pr a ( Pr b _, _ ), _ )' },
};
const DMAKERS = {
  lit: (D) => `make : Int → ${D.T}\nmake n =\n    q = [ n, 2 ]\n    ${D.mk('q')}\n`,
  rep: (D) => `${D.rep}\n\nmake : Int → ${D.T}\nmake n =\n    q = [ n, 2 ]\n    ${D.viaRep('q')}\n`,
  repFresh: (D) => `${D.rep}\n\nmake : Int → ${D.T}\nmake n =\n    ${D.viaRep('[ n, 2 ]')}\n`,
  further: (D) => `inner : Int → ${D.T}\ninner n =\n    q = [ n, 2 ]\n    ${D.mk('q')}\n\n\nmake : Int → ${D.T}\nmake n =\n    inner n\n`,
  built: () => "",
  builtRep: (D) => D.rep,
};
const DMAKE = { built: (D) => `q = [ n, 2 ]\nr = ${D.mk('q')}`, builtRep: (D) => `q = [ n, 2 ]\nr = rep 3 q` };
function genDeep(dname, mname, use, twin) {
  const D = DEEP[dname];
  const k = twin === 'dead' ? 'w = List.set a 0 9\nshow w' : 'w = List.set a 0 9\nshow w ++ "/" ++ show b';
  const pat = D.pat;
  if (mname === 'builtRep' && dname !== 'lst' && dname !== 'gen') return null;
  const match = (x) => `case ${x} of\n    ${pat.replace(/^\((.*)\)$/, '$1')} →\n${ind(k, 8)}\n\n    _ →\n        "-"`;
  const make = DMAKE[mname] ? DMAKE[mname](D) : 'r = make n';
  const fns = [DMAKERS[mname](D)];
  let lines;
  if (use === 'here') lines = `${make}\n${match('r')}`;
  else {
    fns.push(`f : ${D.T} → String\nf t =\n${ind(match('t'), 4)}\n`);
    lines = `${make}\nf r`;
  }
  return program([D.decls, ...fns, `go : Int → String\ngo n =\n${ind(lines, 4)}\n`]);
}


// ---- family `hof` -------------------------------------------------------------------------------------------

// A function of `core/` that hands a callback the elements of a container, and a callback that writes the
// element in place. The `live` twin reads the container after the call; the `dead` twin does not.
const PUSH = "λl → List.push l 9";
const HOFS = {
  map: "shows (List.map ls (" + PUSH + "))",
  indexedMap: "shows (List.indexedMap ls (λi l → List.push l i))",
  filter: "shows (List.filter ls (λl → List.length (List.push l 9) > 0))",
  filterMap: "shows (List.filterMap ls (λl → Just (List.push l 9)))",
  all: "(if List.all ls (λl → List.length (List.push l 9) > 0) then \"t\" else \"f\")",
  any: "(if List.any ls (λl → List.length (List.push l 9) > 5) then \"t\" else \"f\")",
  concatMap: "shows (List.concatMap ls (λl → [ List.push l 9 ]))",
  map2: "shows (List.map2 ls [ 1, 2 ] (λl k → List.push l k))",
  map3: "shows (List.map3 ls [ 1, 2 ] [ 3, 4 ] (λl k j → List.push l (k + j)))",
  sortBy: "shows (List.sortBy ls (λl → List.length (List.push l 9)))",
  sortWith: "shows (List.sortWith ls (λa b → compare (List.length (List.push a 9)) (List.length b)))",
  partition: "shows (List.partition ls (λl → List.length (List.push l 9) > 1)).0",
  foldl: "String.fromInt (List.foldl ls 0 (λl acc → acc + List.length (List.push l 9)))",
  foldr: "String.fromInt (List.foldr ls 0 (λl acc → acc + List.length (List.push l 9)))",
  foldlKeep: "shows (List.foldl ls [] (λl acc → [ …acc, List.push l 9 ]))",
  update: "shows (List.update ls 0 (" + PUSH + "))",
  maybeMap: "show (Maybe.withDefault (Maybe.map (List.head ls) (" + PUSH + ")) [])",
  maybeAndThen: "show (Maybe.withDefault (Maybe.andThen (List.head ls) (λl → Just (List.push l 9))) [])",
  maybeMap2: "show (Maybe.withDefault (Maybe.map2 (List.head ls) (Just 1) (λl k → List.push l k)) [])",
  resultMap: "show (Result.withDefault (Result.map (Ok (Maybe.withDefault (List.head ls) [])) (" + PUSH + ")) [])",
  dictMap: "shows (Dict.values (Dict.map d (λ_ l → List.push l 9)))",
  dictFoldl: "String.fromInt (Dict.foldl d 0 (λ_ l acc → acc + List.length (List.push l 9)))",
  dictFilter: "shows (Dict.values (Dict.filter d (λ_ l → List.length (List.push l 9) > 0)))",
  dictPartition: "shows (Dict.values (Dict.partition d (λ_ l → List.length (List.push l 9) > 1)).0)",
  dictUpdate: "shows (Dict.values (Dict.update d \"a\" (λm → Maybe.map m (" + PUSH + "))))",
};
function genHof(h, twin) {
  const dict = h.startsWith("dict");
  const read = dict ? "shows (Dict.values d)" : "shows ls";
  const lines = ["ls = [ [ n, 2 ], [ 3 ] ]", ...(dict ? ["d = Dict.fromList [ ( \"a\", [ n, 2 ] ), ( \"b\", [ 3 ] ) ]"] : []), "s = " + HOFS[h], twin === "live" ? "s ++ \"/\" ++ " + read : "s"];
  const shows = "shows : List (" + L + ") → String\nshows ls =\n    String.join (List.map ls show) \";\"\n";
  return program([shows, "go : Int → String\ngo n =\n" + ind(lines.join("\n"), 4) + "\n"]).replace("import List\n", (dict ? "import Dict\n" : "") + "import List\n").replace("import String\n", "import Result\nimport String\n");
}


// ---- family `result` -------------------------------------------------------------------------------------------

// A function of `core/` whose answer is a list made from `q`: the answer is written in place, and `q` is read
// after (`live`) or not (`dead`). Each answer that is `q` itself, or shares its storage, must be refused.
const RESULTS = {
  slice: "List.slice q 0 9", copy: "List.copy q", filter: "List.filter q (λ_ → True)", reverse: "List.reverse q",
  concat1: "List.concat [ q ]", concat2: "List.concat [ q, [] ]", concat3: "List.concat [ [], q ]",
  intersperse: "List.intersperse q 0", sort: "List.sort q", sortBy: "List.sortBy q (λx → x)",
  sortWith: "List.sortWith q compare", take: "List.take q 9", drop0: "List.drop q 0", drop1: "List.drop q 1",
  tail: "Maybe.withDefault (List.tail q) []", update: "List.update q 0 (λx → x)",
  partition: "(List.partition q (λ_ → True)).0", appendR: "List.append q []", appendL: "List.append [] q",
  map: "List.map q (λx → x)", filterMap: "List.filterMap q Just", concatMap: "List.concatMap q (λx → [ x ])",
  indexedMap: "List.indexedMap q (λ_ x → x)", map2: "List.map2 q q (λx _ → x)", foldl: "List.foldl q [] (λx acc → [ …acc, x ])",
  foldr: "List.foldr q [] (λx acc → [ x, …acc ])", spread: "[ …q ]", spreadEnd: "[ …q, …[] ]", cons: "List.cons 7 q",
  withDefault: "Maybe.withDefault (Just q) []", unzip: "(List.unzip (List.map q (λx → ( x, x )))).0",
  head: "Maybe.withDefault (List.head [ q ]) []", getElem: "Maybe.withDefault (List.get [ q ] 0) []",
  dictValue: "Maybe.withDefault (Dict.get (Dict.singleton 1 q) 1) []", setValue: "Set.toList (Set.fromList q)",
};
function genResult(r, len, twin) {
  const q = ["[]", "[ n ]", "[ n, 2 ]"][len];
  const lines = ["q = " + q, "w = List.push (" + RESULTS[r] + ") 9", twin === "live" ? "show w ++ \"/\" ++ show q" : "show w"];
  return program(["go : Int → String\ngo n =\n" + ind(lines.join("\n"), 4) + "\n"]).replace("import List\n", "import Dict\nimport List\n").replace("import String\n", "import Set\nimport String\n");
}

// ---- write ------------------------------------------------------------------------------------------------------

fs.mkdirSync(out, { recursive: true });
const list = [];
const emit = (name, src) => {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), src);
  list.push(path.resolve(d));
};
for (const s of Object.keys(SHAPES)) for (const m of Object.keys(MAKERS)) for (const u of Object.keys(USES)) emit(`two.${s}.${m}.${u}`, genTwo(s, m, u));
for (const c of Object.keys(CALLEES)) for (const w of Object.keys(WRITES)) for (const r of Object.keys(READS)) for (const t of ['live', 'dead']) {
  if (CALLEES[c].method && r === 'show') continue;
  emit(`order.${c}.${w}.${r}.${t}`, genOrder(c, w, r, t));
}
for (const d of Object.keys(DEEP)) for (const m of Object.keys(DMAKERS)) for (const u of ['here', 'callee']) for (const t of ['live', 'dead']) {
  const src = genDeep(d, m, u, t);
  if (src) emit(`deep.${d}.${m}.${u}.${t}`, src);
}
for (const h of Object.keys(HOFS)) for (const t of ['live', 'dead']) emit(`hof.${h}.${t}`, genHof(h, t));
for (const r of Object.keys(RESULTS)) for (const len of [0, 1, 2]) for (const t of ['live', 'dead']) emit(`result.${r}.len${len}.${t}`, genResult(r, len, t));
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
