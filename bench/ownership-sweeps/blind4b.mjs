// blind4b.mjs <outdir> [filter]: research report 119, a fourth blind test of ownership checker v3 (reader B).
//
// Three families, each a cross product, each program with a `live` twin (the old value is read after an
// in-place write: the checker must refuse it, or print the same) and a `dead` twin (nothing reads it: safe).
//
// 1. `hold.<holder>.<writer>.<twin>`: one list `xs` and a holder `h` that reaches it in one of the ways the
//    language has (a constructor, a record with a row variable, a `Maybe` through `Maybe.map`, a `Result`
//    through `?` and `andThen`, a `Dict`, a closure, a partial application, a method of a user type, a
//    `where` method, a type of another module, a recursive type, a fold accumulator, `List.map` with an
//    identity, a `case` that joins, a local recursive function, a pipe). The writer writes `xs` or the list
//    that `h` gives back, by `List.push`, `List.set`, a spread, `++`, a callee that writes, or a method.
//    The live twin then reads the other name.
// 2. `cell.<how>.<edit>.<twin>`: a list put in a `Ref` (by `make`, `set`, the answer of `update` or `modify`)
//    and edited through the cell, while its first name is read.
// 3. `cb.<runner>.<act>.<twin>`: a callback of `core/` (`List.map`, `indexedMap`, `filter`, `foldl`,
//    `foldr`, `filterMap`, `sortBy`, `update`, `Maybe.map`, `Result.map`, `Dict.map`, `Dict.foldl`) that
//    writes the element or the accumulator it is handed while another element, the accumulator or the list
//    holds the same array.
//
// Programs are `<name>/Main.beni` (and a second module where the holder needs one). See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind4b.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body, where = '') =>
  `${name} : ${sig}\n${where ? `    where ${where}\n` : ''}${name}${params ? ' ' + params : ''} =\n${ind(body, 4)}\n`;
const pub = (text) => `pub ${text}`;
const caseOf = (scrut, arms) => `case ${scrut} of\n${arms.map(([p, e]) => `    ${p} →\n${ind(e, 8)}`).join('\n\n')}`;

const BASE_IMPORTS = ['import List', 'import Node exposing (Program)', 'import String'];
const SHOW = [
  fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
  fn('shows', 'List (List Int) → String', 'ls', 'String.join (List.map ls show) ";"'),
];

function program({ imports = [], decls = [], body, files = {} }) {
  const main = [
    [...new Set([...imports, ...BASE_IMPORTS])].sort().join('\n') + '\n',
    ...SHOW,
    ...decls,
    fn('go', 'Int → String', 'n', body),
    'main : Program\nmain =\n    Node.print (go 0)\n',
  ].join('\n\n');
  return { 'Main.beni': main, ...files };
}

// ---- family 1: holders -----------------------------------------------------------------------------------
//
// A holder: `make` is an expression over `xs` bound to `h`; `peek` is an expression over `h` whose value is the
// list `h` holds (the same array as `xs`). `decls`, `imports`, `files` as for `program`.
const just = (e) => caseOf(e, [['Just l', 'l'], ['Nothing', '[]']]);
const HOLDERS = {
  ctor: { decls: ['type Box\n    = Box (List Int)\n'], make: 'Box xs', peek: (h) => caseOf(h, [['Box l', 'l']]) },
  ctor2: { decls: ['type Two\n    = Two Int (List Int)\n'], make: 'Two 1 xs', peek: (h) => caseOf(h, [['Two _ l', 'l']]) },
  tuple: { make: '( 0, xs )', peek: (h) => `${h}.1` },
  record: { make: '{ k = 0, l = xs }', peek: (h) => `${h}.l` },
  rowSet: { decls: [fn('setK', '{ r | k : Int } → { r | k : Int }', 'rec', '{ rec | k = 1 }')], make: 'setK { k = 0, l = xs }', peek: (h) => `${h}.l` },
  rowGet: { decls: [fn('getL', '{ r | l : List Int } → List Int', 'rec', 'rec.l')], make: '{ k = 0, l = xs }', peek: (h) => `getL ${h}` },
  maybeMap: { make: 'Maybe.map (Just 0) λ_ → xs', imports: ['import Maybe'], peek: (h) => `(${just(h)})` },
  maybeAndThen: { make: 'Maybe.andThen (Just xs) Just', imports: ['import Maybe'], peek: (h) => `(${just(h)})` },
  withDefault: { make: 'Maybe.withDefault Nothing xs', imports: ['import Maybe'], peek: (h) => h },
  resultTry: {
    decls: [fn('pass', 'Result String (List Int) → Result String (List Int)', 'r', 'v = r?\nOk v')],
    make: 'pass (Ok xs)', peek: (h) => `(${caseOf(h, [['Ok l', 'l'], ['Err _', '[]']])})`,
  },
  resultAndThen: {
    imports: ['import Result'], make: 'Result.andThen (Ok 0) λ_ → Ok xs',
    peek: (h) => `(${caseOf(h, [['Ok l', 'l'], ['Err _', '[]']])})`, sig: 'Result String (List Int)',
  },
  dict: { imports: ['import Dict exposing (Dict)'], make: 'Dict.insert Dict.empty 1 xs', peek: (h) => `(${just(`Dict.get ${h} 1`)})` },
  dictValues: { imports: ['import Dict exposing (Dict)'], make: 'Dict.insert Dict.empty 1 xs', peek: (h) => `(${caseOf(`Dict.values ${h}`, [['[ l ]', 'l'], ['_', '[]']])})` },
  closure: { make: 'λ⊤ → xs', peek: (h) => `${h} ⊤` },
  partial: { decls: [fn('pick', 'List Int, Int → List Int', 'l _', 'l')], make: 'pick xs _', peek: (h) => `${h} 0` },
  closureRec: { make: '{ get = λ⊤ → xs }', peek: (h) => `${h}.get ⊤` },
  method: {
    decls: ['type Bag\n    = Bag (List Int)\n', fn('items', 'Bag → List Int', 'b', caseOf('b', [['Bag l', 'l']]))],
    make: 'Bag xs', peek: (h) => `${h}.items`,
  },
  whereGet: {
    decls: [
      'type Bag\n    = Bag (List Int)\n',
      fn('items', 'Bag → List Int', 'b', caseOf('b', [['Bag l', 'l']])),
      fn('itemsOf', 'a → List Int', 'x', 'x.items', 'a.items : a → List Int'),
    ],
    make: 'Bag xs', peek: (h) => `itemsOf ${h}`,
  },
  module: {
    imports: ['import Stack exposing (Stack)'],
    files: { 'Stack.beni': ['import List\n', 'pub type Stack\n    = Stack Int (List Int)\n', pub(fn('make', 'List Int → Stack', 'l', 'Stack 0 l')), pub(fn('items', 'Stack → List Int', 's', caseOf('s', [['Stack _ l', 'l']])))].join('\n\n') },
    make: 'Stack.make xs', peek: (h) => `Stack.items ${h}`,
  },
  moduleOpaque: {
    imports: ['import Pile exposing (Pile)'],
    files: { 'Pile.beni': ['import List\n', 'pub opaque type Pile\n    = Pile (List Int) (List Int)\n', pub(fn('make', 'List Int → Pile', 'l', 'Pile l []')), pub(fn('top', 'Pile → List Int', 's', caseOf('s', [['Pile l _', 'l']])))].join('\n\n') },
    make: 'Pile.make xs', peek: (h) => `Pile.top ${h}`,
  },
  tree: {
    decls: ['type Tree\n    = Leaf (List Int)\n    | Node Tree Tree\n',
      fn('leftmost', 'Tree → List Int', 't', caseOf('t', [['Leaf l', 'l'], ['Node a _', 'leftmost a']]))],
    make: 'Node (Node (Leaf xs) (Leaf [])) (Leaf [])', peek: (h) => `leftmost ${h}`,
  },
  deep: {
    decls: ['type Deep\n    = Deep (List Deep) (List Int)\n',
      fn('inner', 'Deep → List Int', 'd', caseOf('d', [['Deep [ k, …_ ] _', 'inner k'], ['Deep _ l', 'l']]))],
    make: 'Deep [ Deep [] xs ] []', peek: (h) => `inner ${h}`,
  },
  foldAcc: { make: 'List.foldl [ 1, 2 ] xs λ_ acc → acc', peek: (h) => h },
  foldrAcc: { make: 'List.foldr [ 1, 2 ] xs λ_ acc → acc', peek: (h) => h },
  mapId: { make: 'List.map [ xs ] λl → l', peek: (h) => `(${caseOf(h, [['[ l ]', 'l'], ['_', '[]']])})` },
  sortBy: { make: 'List.sortBy [ xs ] List.length', peek: (h) => `(${caseOf(h, [['[ l ]', 'l'], ['_', '[]']])})` },
  filter: { make: 'List.filter [ xs, [] ] λl → List.length l > 0', peek: (h) => `(${caseOf(h, [['[ l ]', 'l'], ['_', '[]']])})` },
  reverse: { make: 'List.reverse [ [], xs ]', peek: (h) => `(${caseOf(h, [['[ l, _ ]', 'l'], ['_', '[]']])})` },
  concat: { make: 'List.concat [ [ xs ], [] ]', peek: (h) => `(${caseOf(h, [['[ l ]', 'l'], ['_', '[]']])})` },
  join: { make: 'if n > 5 then [] else xs', peek: (h) => h },
  caseJoin: { make: caseOf('n', [['0', 'xs'], ['_', '[ 1 ]']]), peek: (h) => h },
  recurse: {
    decls: [fn('down', 'Int, List Int → List Int', 'k l', 'if k ≤ 0 then\n    l\nelse\n    down (k - 1) l')],
    make: 'down 3 xs', peek: (h) => h,
  },
  localRec: {
    make: 'loop : Int, List Int → List Int\nloop k l =\n    if k ≤ 0 then\n        l\n    else\n        loop (k - 1) l\nloop 3 xs',
    peek: (h) => h,
  },
  pipe: { decls: [fn('wrap', 'List Int → Maybe (List Int)', 'l', 'Just l')], make: 'xs ▷ wrap', peek: (h) => `(${just(h)})` },
  pipeBack: { decls: [fn('wrap', 'List Int → Maybe (List Int)', 'l', 'Just l')], make: 'wrap ◁ xs', peek: (h) => `(${just(h)})` },
  drop0: { make: 'List.drop xs 0', peek: (h) => h },
  tail: { make: '[ 7, …xs ]', peek: (h) => `(${caseOf(h, [['[ _, …r ]', 'r'], ['_', '[]']])})` },
  viewCons: {
    make: caseOf('[ 7, …xs ]', [['[ x, …r ]', '[ x, …r ]'], ['_', '[]']]),
    peek: (h) => `(${caseOf(h, [['[ _, …r ]', 'r'], ['_', '[]']])})`,
  },
  initView: { make: '[ …xs, 7 ]', peek: (h) => `(${caseOf(h, [['[ …i, _ ]', 'i'], ['_', '[]']])})` },
  andThen: { decls: [fn('twice', 'List Int → List Int × List Int', 'l', '( l, l )')], make: 'twice xs', peek: (h) => `${h}.1` },
};

// Writers: `w` is the expression that writes, given the list it writes (`t`); `self` says that the writer
// also reads nothing else. The writer writes either `xs` (then the live twin reads `peek h`) or `peek h`
// (then the live twin reads `xs`).
const WRITERS = {
  push: { w: (t) => `List.push ${t} 9` },
  set: { w: (t) => `List.set ${t} 0 9` },
  spread: { w: (t) => `[ …${t}, 9 ]` },
  append: { w: (t) => `${t} ++ [ 9 ]` },
  callee: { decls: [fn('bump', 'List Int → List Int', 'l', 'List.push l 9')], w: (t) => `bump ${t}` },
  pipe: { w: (t) => `${t} ▷ List.push 9` },
  method: { w: (t) => `${t}.push 9` },
  update: { w: (t) => `List.update ${t} 0 λx → x + 1` },
};

function holdProgram(hname, wname, side, twin) {
  const H = HOLDERS[hname], W = WRITERS[wname];
  const decls = [...(H.decls || []), ...(W.decls || [])];
  const peek = H.peek('h');
  const lines = ['xs = [ n, 5 ]'];
  if (H.make.includes('\n')) {
    lines.push(`h =\n${ind(H.make, 4)}`);
  } else lines.push(`h = ${H.make}`);
  // `side`: `x` writes xs and reads h; `h` writes what h gives back and reads xs.
  const target = side === 'x' ? 'xs' : `(${peek})`;
  lines.push(`a = ${W.w(target)}`);
  const other = side === 'x' ? `show (${peek})` : 'show xs';
  lines.push(twin === 'live' ? `show a ++ "|" ++ ${other}` : 'show a');
  return program({ imports: H.imports || [], decls, body: lines.join('\n'), files: H.files || {} });
}

// ---- family 2: cells -------------------------------------------------------------------------------------
const CELL_IN = {
  make: { pre: 'r = Ref.make xs' },
  set: { pre: 'r = Ref.make []\nRef.set r xs' },
  update: { pre: 'r = Ref.make []\nRef.update r λ_ → xs' },
  modify: { pre: 'r = Ref.make []\n_ = Ref.modify r λ_ → ( 0, xs )' },
};
const CELL_EDIT = {
  update: { e: 'Ref.update r λl → List.push l 9', after: 'show (Ref.get r)' },
  modify: { e: 'old = Ref.modify r λl → ( l, [] )\na = List.push old 9', after: 'show a' },
  get: { e: 'a = List.push (Ref.get r) 9', after: 'show a' },
  modifyIn: { e: 'k = Ref.modify r λl → ( 0, List.push l 9 )', after: 'show (Ref.get r)' },
};
function cellProgram(how, edit, twin) {
  const I = CELL_IN[how], E = CELL_EDIT[edit];
  const body = ['xs = [ n, 5 ]', I.pre, E.e, twin === 'live' ? `${E.after} ++ "|" ++ show xs` : E.after].join('\n');
  return program({ imports: ['import Ref exposing (Ref)'], body });
}

// ---- family 3: callbacks of core -------------------------------------------------------------------------
//
// `xs` is a list of lists in which one array is at two places (`dup`), or a list of lists and an accumulator
// that holds one of its arrays (`acc`), or a list of distinct arrays (`apart`, the safe control). The runner
// hands the callback the element; the act writes it.
const CB_SHAPES = {
  dup: 'e0 = [ n ]\nxs = [ e0, e0 ]',
  apart: 'xs = [ [ n ], [ n ] ]',
  outer: 'e0 = [ n ]\nxs = [ e0, [ 5 ] ]',
};
const CB_RUNNERS = {
  map: (act) => `r = List.map xs λx → ${act('x')}\nshows r`,
  indexedMap: (act) => `r = List.indexedMap xs λ_ x → ${act('x')}\nshows r`,
  filterMap: (act) => `r = List.filterMap xs λx → Just (${act('x')})\nshows r`,
  foldl: (act) => `r = List.foldl xs [] λx acc → List.push acc (${act('x')})\nshows r`,
  foldr: (act) => `r = List.foldr xs [] λx acc → List.push acc (${act('x')})\nshows r`,
  update: (act) => `r = List.update xs 0 λx → ${act('x')}\nshows r`,
  update1: (act) => `r = List.update xs 1 λx → ${act('x')}\nshows r`,
  maybeMap: (act) => `r = Maybe.map (List.head xs) λx → ${act('x')}\nshow (Maybe.withDefault r [])`,
  dictMap: (act) => `d = Dict.fromList (List.indexedMap xs λi x → ( i, x ))\nr = Dict.map d λ_ x → ${act('x')}\nshows (Dict.values r)`,
  dictFold: (act) => `d = Dict.fromList (List.indexedMap xs λi x → ( i, x ))\nr = Dict.foldl d [] λ_ x acc → List.push acc (${act('x')})\nshows r`,
  sortBy: (act) => `r = List.map (List.sortBy xs List.length) λx → ${act('x')}\nshows r`,
};
const CB_ACTS = {
  push: (x) => `List.push ${x} 9`,
  set: (x) => `List.set ${x} 0 9`,
  spread: (x) => `[ …${x}, 9 ]`,
  twice: (x) => `List.push (List.push ${x} 9) 8`,
};
function cbProgram(shape, runner, act, twin) {
  // live: the outer element (e0) is read afterwards; dead: only the result.
  let body = [CB_SHAPES[shape], CB_RUNNERS[runner](CB_ACTS[act])].join('\n');
  if (twin === 'live') {
    const lines = body.split('\n');
    const last = lines.pop();
    lines.push(`${last} ++ "|" ++ shows xs`);
    body = lines.join('\n');
  }
  return program({ imports: ['import Dict exposing (Dict)', 'import Maybe'], body });
}


// ---- family 4: one array at two places of a list ---------------------------------------------------------
//
// A maker builds `r : List (List Int)` from two arrays `a` and `b`. In the live twin both are `e0`, so
// one array is at two places of `r`; in the dead twin `b` is a new list. A writer then edits elements of
// `r` and the program prints all of it: an in-place edit of one place shows at the other.
const DUP_MAKERS = {
  lit: (a, b) => `[ ${a}, ${b} ]`,
  concat: (a, b) => `List.concat [ [ ${a} ], [ ${b} ] ]`,
  append: (a, b) => `[ ${a} ] ++ [ ${b} ]`,
  spread: (a, b) => `[ …[ ${a} ], …[ ${b} ] ]`,
  spreadItem: (a, b) => `[ …[ ${a} ], ${b} ]`,
  push: (a, b) => `List.push [ ${a} ] ${b}`,
  cons: (a, b) => `[ ${a}, …[ ${b} ] ]`,
  insertAt: (a, b) => `List.insertAt [ ${a} ] 0 ${b}`,
  set: (a, b) => `List.set [ ${a}, [] ] 1 ${b}`,
  reverse: (a, b) => `List.reverse [ ${a}, ${b} ]`,
  sortBy: (a, b) => `List.sortBy [ ${a}, ${b} ] List.length`,
  sortWith: (a, b) => `List.sortWith [ ${a}, ${b} ] λx y → Basics.compare (List.length x) (List.length y)`,
  filter: (a, b) => `List.filter [ ${a}, ${b} ] λ_ → True`,
  filterMap: (a, b) => `List.filterMap [ ${a}, ${b} ] Just`,
  mapId: (a, b) => `List.map [ ${a}, ${b} ] λl → l`,
  indexedMap: (a, b) => `List.indexedMap [ ${a}, ${b} ] λ_ l → l`,
  foldl: (a, b) => `List.foldl [ ${a}, ${b} ] [] λl acc → List.push acc l`,
  foldr: (a, b) => `List.foldr [ ${a}, ${b} ] [] λl acc → List.push acc l`,
  intersperse: (a, b) => `List.intersperse [ ${a}, [ 7 ] ] ${b}`,
  concatMap: (a, b) => `List.concatMap [ 1, 2 ] λk → if k == 1 then [ ${a} ] else [ ${b} ]`,
  map2: (a, b) => `List.map2 [ 1, 2 ] [ 3, 4 ] λi _ → if i == 1 then ${a} else ${b}`,
  initialize: (a, b) => `List.initialize 2 λi → if i == 0 then ${a} else ${b}`,
  foldCapture: (a, b) => `List.foldl [ 1, 2 ] [] λk acc → List.push acc (if k == 1 then ${a} else ${b})`,
  dictValues: (a, b) => `Dict.values (Dict.insert (Dict.insert Dict.empty 1 ${a}) 2 ${b})`,
  dictFold: (a, b) => `Dict.foldl (Dict.fromList [ ( 1, ${a} ), ( 2, ${b} ) ]) [] λ_ v acc → List.push acc v`,
  dictMap: (a, b) => `Dict.values (Dict.map (Dict.fromList [ ( 1, 0 ), ( 2, 0 ) ]) λk _ → if k == 1 then ${a} else ${b})`,
  dictUpdate: (a, b) => `Dict.values (Dict.update (Dict.fromList [ ( 1, ${a} ) ]) 2 λ_ → Just ${b})`,
  dictUnion: (a, b) => `Dict.values (Dict.union (Dict.singleton 1 ${a}) (Dict.singleton 2 ${b}))`,
  maybeMap: (a, b) => `Maybe.withDefault (Maybe.map (Just ${a}) λx → [ x, ${b} ]) []`,
  maybeMap2: (a, b) => `Maybe.withDefault (Maybe.map2 (Just ${a}) (Just ${b}) λx y → [ x, y ]) []`,
  combine: (a, b) => `Result.withDefault (Result.combine [ Ok ${a}, Ok ${b} ]) []`,
  resultMap2: (a, b) => `Result.withDefault (Result.map2 (Ok ${a}) (Ok ${b}) λx y → [ x, y ]) []`,
  partition: (a, b) => `(List.partition [ ${a}, ${b} ] λ_ → True).0`,
  unzip: (a, b) => `(List.unzip [ ( ${a}, 1 ), ( ${b}, 2 ) ]).0`,
  pairFn: (a, b) => `listOfPair (pairOf ${a} ${b})`,
  rowFn: (a, b) => `listOfRow (keepRow { p = ${a}, q = ${b}, z = 0 })`,
  localRec: (a, b) => `loop : Int, List (List Int) → List (List Int)\nloop k acc =\n    if k ≤ 0 then\n        acc\n    else\n        loop (k - 1) (List.push acc (if k == 1 then ${a} else ${b}))\nloop 2 []`,
  topRec: (a, b) => `collect 2 ${a} ${b} []`,
  caseJoin: (a, b) => `case n of\n    0 →\n        [ ${a}, ${b} ]\n\n    _ →\n        [ ${a} ]`,
  drop: (a, b) => `List.drop [ [ 7 ], ${a}, ${b} ] 1`,
  take: (a, b) => `List.take [ ${a}, ${b}, [ 7 ] ] 2`,
  slice: (a, b) => `List.slice [ [ 7 ], ${a}, ${b} ] 1 3`,
  removeAt: (a, b) => `List.removeAt [ ${a}, [ 7 ], ${b} ] 1`,
  swap: (a, b) => `List.swap [ ${a}, ${b} ] 0 1`,
  pop: (a, b) => `List.pop [ ${a}, ${b}, [ 7 ] ]`,
  setTwice: (a, b) => `List.set (List.set [ [], [] ] 0 ${a}) 1 ${b}`,
  updateTo: (a, b) => `List.update [ ${a}, [] ] 1 λ_ → ${b}`,
  viaTuple: (a, b) => `case ( ${a}, ${b} ) of\n    ( x, y ) →\n        [ x, y ]`,
  viaMaybe: (a, b) => `case Just ${b} of\n    Just y →\n        [ ${a}, y ]\n\n    Nothing →\n        []`,
  viaRecordUpdate: (a, b) => `base = { p = ${a}, q = [], z = 0 }\nlistOfRow { base | q = ${b} }`,
};
const DUP_DECLS = [
  fn('pairOf', 'x, y → x × y', 'x y', '( x, y )'),
  fn('listOfPair', 'List Int × List Int → List (List Int)', 'p', '[ p.0, p.1 ]'),
  fn('keepRow', '{ r | z : Int } → { r | z : Int }', 'rec', '{ rec | z = 1 }'),
  fn('listOfRow', '{ p : List Int, q : List Int, z : Int } → List (List Int)', 'rec', '[ rec.p, rec.q ]'),
  fn('collect', 'Int, List Int, List Int, List (List Int) → List (List Int)', 'k a b acc', 'if k ≤ 0 then\n    acc\nelse\n    collect (k - 1) a b (List.push acc (if k == 1 then a else b))'),
];
const DUP_WRITERS = {
  upd0: 'List.update r 0 λl → List.push l 9',
  upd1: 'List.update r 1 λl → List.set l 0 9',
  map: 'List.map r λl → List.push l 9',
  indexedMap: 'List.indexedMap r λ_ l → List.push l 9',
  foldl: 'List.foldl r [] λl acc → List.push acc (List.push l 9)',
  pattern: caseOf('r', [['[ x, y ]', '[ List.push x 9, y ]'], ['_', 'r']]),
  patternRest: caseOf('r', [['[ x, …rest ]', '[ List.push x 9, …rest ]'], ['_', 'r']]),
  patternLate: caseOf('r', [['[ x, y ]', 'u = List.push x 9\n[ y, u ]'], ['_', 'r']]),
};
function dupProgram(maker, writer, twin) {
  const b = twin === 'live' ? 'e0' : '[ n ]';
  const make = DUP_MAKERS[maker]('e0', b);
  const lines = ['e0 = [ n ]', make.includes('\n') ? `r =\n${ind(make, 4)}` : `r = ${make}`];
  const w = DUP_WRITERS[writer];
  lines.push(w.includes('\n') ? `s =\n${ind(w, 4)}` : `s = ${w}`);
  lines.push('shows s');
  return program({ imports: ['import Dict exposing (Dict)', 'import Maybe', 'import Result'], decls: DUP_DECLS, body: lines.join('\n') });
}


// ---- family 5: the same through a module ------------------------------------------------------------------
//
// The generic helpers live in module `Help`, so their contracts cross a module as label paths. `mk` builds
// `r : List (List Int)` from `a` and `b` (both `e0` in the live twin) through them.
const HELP = [
  'import List\n',
  'pub type Two a\n    = Two a a\n',
  'pub type Tree a\n    = Node a (List (Tree a))\n',
  pub(fn('pairOf', 'x, y → x × y', 'x y', '( x, y )')),
  pub(fn('dupe', 'x → x × x', 'x', '( x, x )')),
  pub(fn('swap', 'x × y → y × x', 'p', '( p.1, p.0 )')),
  pub(fn('twoOf', 'x, x → Two x', 'x y', 'Two x y')),
  pub(fn('twoList', 'Two x → List x', 't', caseOf('t', [['Two x y', '[ x, y ]']]))),
  pub(fn('listOfPair', 'x × x → List x', 'p', '[ p.0, p.1 ]')),
  pub(fn('keepRow', '{ r | z : Int } → { r | z : Int }', 'rec', '{ rec | z = 1 }')),
  pub(fn('rowList', '{ r | p : x, q : x } → List x', 'rec', '[ rec.p, rec.q ]')),
  pub(fn('collect', 'Int, x, x, List x → List x', 'k a b acc', 'if k ≤ 0 then\n    acc\nelse\n    collect (k - 1) a b (List.push acc (if k == 1 then a else b))')),
  pub(fn('leaf', 'x → Tree x', 'x', 'Node x []')),
  pub(fn('node', 'x, Tree x → Tree x', 'x t', 'Node x [ t ]')),
  pub(fn('values', 'Tree x → List x', 't', caseOf('t', [['Node x kids', 'List.foldl kids [ x ] λk acc → acc ++ values k']]))),
  pub(fn('repeatOf', 'x, Int → List x', 'x k', 'List.repeat x k')),
  pub(fn('wrap', 'x → List x', 'x', '[ x ]')),
  pub(fn('applyTo', '(x → y), x → y', 'f x', 'f x')),
  pub(fn('pairWith', '(x → y), x → y × y', 'f x', '( f x, f x )')),
].join('\n\n');
const MOD_MAKERS = {
  pairOf: (a, b) => `listOfPair (pairOf ${a} ${b})`,
  dupe: (a) => 'listOfPair (dupe ' + a + ')',
  swap: (a, b) => `listOfPair (swap ( ${a}, ${b} ))`,
  two: (a, b) => `twoList (twoOf ${a} ${b})`,
  row: (a, b) => `rowList (keepRow { p = ${a}, q = ${b}, z = 0 })`,
  collect: (a, b) => `collect 2 ${a} ${b} []`,
  tree: (a, b) => `values (node ${a} (leaf ${b}))`,
  repeat: (a) => `repeatOf ${a} 2`,
  wrapAppend: (a, b) => `wrap ${a} ++ wrap ${b}`,
  applyPair: (a, b) => `listOfPair (applyTo (λx → ( x, ${b} )) ${a})`,
  pairWith: (a) => `listOfPair (pairWith (λx → x) ${a})`,
  pairWithCap: (a, b) => `listOfPair (pairWith (λ_ → ${b}) ${a})`,
};
function modProgram(maker, writer, twin) {
  const b = twin === 'live' ? 'e0' : '[ n ]';
  const mk = MOD_MAKERS[maker];
  // A maker of one argument has no dead twin of its own: its dead twin is two literals.
  const make = mk.length === 1 ? (twin === 'live' ? mk('e0') : '[ e0, [ n ] ]') : mk('e0', b);
  const w = DUP_WRITERS[writer];
  const names = /\b(pairOf|dupe|swap|twoOf|twoList|listOfPair|keepRow|rowList|collect|leaf|node|values|repeatOf|wrap|applyTo|pairWith)\b/g;
  const lines = ['e0 = [ n ]', `r = ${make.replace(names, 'Help.$1')}`, w.includes('\n') ? `s =\n${ind(w, 4)}` : `s = ${w}`, 'shows s'];
  return program({ imports: ['import Help'], body: lines.join('\n'), files: { 'Help.beni': HELP } });
}


// ---- family 6: random straight-line programs -------------------------------------------------------------
//
// `rand.<seed>.any`: a seeded random block of 6 to 14 bindings over lists, lists of lists, pairs, records,
// `Maybe`s and functions, each made of earlier ones by a write, a construction, a projection, a pattern, a
// branch, a call of a helper, a lambda or a callback of `core/`. The block then prints a random subset of
// its names. Every program has one twin: any accepted program must print what the plain build prints.
const RAND_DECLS = [
  fn('idL', 'List Int → List Int', 'l', 'l'),
  fn('bumpL', 'List Int → List Int', 'l', 'List.push l 7'),
  fn('pick', 'List Int, List Int → List Int', 'l _', 'l'),
  fn('pickR', 'List Int, List Int → List Int', '_ m', 'm'),
  fn('both', 'List Int → List Int × List Int', 'l', '( l, l )'),
  fn('swapP', 'List Int × List Int → List Int × List Int', 'p', '( p.1, p.0 )'),
  fn('firstOr', 'List (List Int), List Int → List Int', 'll d', caseOf('ll', [['[ x, …_ ]', 'x'], ['_', 'd']])),
  fn('setA', '{ r | a : List Int } → { r | a : List Int }', 'rec', '{ rec | a = List.push rec.a 3 }'),
  fn('runF', '(List Int → List Int), List Int → List Int', 'f l', 'f l'),
  fn('twiceF', '(List Int → List Int), List Int → List Int', 'f l', 'f (f l)'),
  fn('keepF', '(List Int → List Int), List Int → List Int × (List Int → List Int)', 'f l', '( f l, f )'),
  fn('showP', 'List Int × List Int → String', 'p', 'show p.0 ++ "/" ++ show p.1'),
  fn('showR', '{ a : List Int, b : List Int } → String', 'r', 'show r.a ++ "/" ++ show r.b'),
  fn('showM', 'Maybe (List Int) → String', 'm', caseOf('m', [['Just l', 'show l'], ['Nothing', '"-"']])),
];
function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
function randProgram(seed) {
  const r = rng(seed * 2654435761);
  const pickOf = (xs) => xs[Math.floor(r() * xs.length)];
  const env = { L: [], LL: [], P: [], R: [], M: [], F: [] };
  const lines = [];
  let k = 0;
  const v = (t) => env[t].length ? pickOf(env[t]) : null;
  const L = () => v('L') ?? '[ n ]';
  const LL = () => v('LL') ?? `[ ${L()} ]`;
  const P = () => v('P') ?? `( ${L()}, ${L()} )`;
  const R = () => v('R') ?? `({ a = ${L()}, b = ${L()} })`;
  const M = () => v('M') ?? `(Just ${L()})`;
  const F = () => v('F') ?? 'bumpL';
  const num = () => String(Math.floor(r() * 9) + 1);
  const makers = {
    L: [
      () => `[ n, ${num()} ]`, () => `List.push ${L()} ${num()}`, () => `List.set ${L()} 0 ${num()}`,
      () => `[ …${L()}, ${num()} ]`, () => `${L()} ++ ${L()}`, () => `List.reverse ${L()}`, () => `List.drop ${L()} 1`,
      () => `${P()}.0`, () => `${P()}.1`, () => `${R()}.a`, () => `${R()}.b`, () => `Maybe.withDefault ${M()} []`,
      () => `${F()} ${L()}`, () => `idL ${L()}`, () => `bumpL ${L()}`, () => `pick ${L()} ${L()}`, () => `pickR ${L()} ${L()}`,
      () => `if n > 3 then ${L()} else ${L()}`, () => `firstOr ${LL()} ${L()}`, () => `List.map ${L()} λx → x + 1`,
      () => `List.copy ${L()}`, () => `runF ${F()} ${L()}`, () => `twiceF ${F()} ${L()}`, () => `(keepF ${F()} ${L()}).0`,
      () => `List.foldl ${LL()} ${L()} λx acc → acc ++ x`, () => `List.foldl ${L()} ${L()} λx acc → List.push acc x`,
      () => `[ ${num()}, …${L()} ]`, () => '(' + caseOf(L(), [['[ _, …rest ]', 'rest'], ['_', '[]']]) + ')',
      () => `(setA ${R()}).a`, () => `(swapP ${P()}).0`, () => `(both ${L()}).1`,
      () => '(' + caseOf(LL(), [['[ x, y ]', `if n > 2 then List.push x 1 else y`], ['_', L()]]) + ')',
      () => '(' + caseOf(P(), [['( x, y )', 'if n > 2 then x else List.push y 2']]) + ')',
      () => `List.foldl ${LL()} ${L()} λx acc → List.push acc (List.length x)`, () => `Maybe.withDefault (Maybe.map ${M()} ${F()}) ${L()}`,
      () => `(λf → f ${L()}) ${F()}`, () => `(λx → [ …x, 1 ]) ${L()}`,
    ],
    LL: [
      () => `[ ${L()}, ${L()} ]`, () => `List.push ${LL()} ${L()}`, () => `List.update ${LL()} 0 λx → List.push x ${num()}`,
      () => `List.set ${LL()} 0 ${L()}`, () => `List.map ${LL()} λx → List.push x ${num()}`, () => `List.map ${LL()} λx → x`,
      () => `[ …${LL()}, ${L()} ]`, () => `List.reverse ${LL()}`, () => `List.filter ${LL()} λx → List.length x > 0`,
      () => `List.concat [ ${LL()}, [ ${L()} ] ]`, () => `List.map ${LL()} ${F()}`, () => `List.indexedMap ${LL()} λ_ x → ${F()} x`,
      () => `List.foldl ${LL()} [] λx acc → List.push acc (List.push x 1)`, () => `List.update ${LL()} 1 ${F()}`,
      () => `List.map ${LL()} λx → x ++ ${L()}`, () => `List.foldl ${L()} ${LL()} λk acc → List.update acc 0 λx → List.push x k`,
      () => `List.sortBy ${LL()} List.length`, () => `List.indexedMap ${LL()} λi x → if i == 0 then List.push x 1 else x`,
      () => `List.filterMap ${LL()} λx → if List.length x > 1 then Just (List.push x 2) else Nothing`,
    ],
    P: [() => `( ${L()}, ${L()} )`, () => `swapP ${P()}`, () => `both ${L()}`, () => `( List.push ${P()}.0 1, ${L()} )`, () => `(λq → ( q.0, ${L()} )) (keepF ${F()} ${L()})`],
    R: [() => `{ a = ${L()}, b = ${L()} }`, () => env.R.length ? `{ ${v('R')} | a = ${L()} }` : `{ a = ${L()}, b = ${L()} }`, () => `setA ${R()}`],
    M: [() => `Just ${L()}`, () => `Maybe.map ${M()} λx → List.push x ${num()}`, () => `Maybe.map ${M()} ${F()}`, () => 'Nothing'],
    F: [() => `λx → List.push x ${num()}`, () => 'λx → x', () => `λ_ → ${L()}`, () => `λx → x ++ ${L()}`, () => 'bumpL', () => `pick ${L()} _`, () => `(keepF ${F()} ${L()}).1`],
  };
  const types = ['L', 'L', 'L', 'LL', 'LL', 'P', 'R', 'M', 'F'];
  const count = 6 + Math.floor(r() * 9);
  for (let i = 0; i < count; i++) {
    const t = pickOf(types);
    const e = pickOf(makers[t])();
    const name = `v${k++}`;
    lines.push(`${name} = ${e}`);
    env[t].push(name);
  }
  const shown = { L: 'show', LL: 'shows', P: 'showP', R: 'showR', M: 'showM' };
  const outs = [];
  for (const t of Object.keys(shown)) for (const name of env[t]) if (r() < 0.25) outs.push(`${shown[t]} ${name}`);
  for (const name of env.F) if (r() < 0.3) outs.push(`show (${name} [ 0 ])`);
  if (outs.length === 0) outs.push('"-"');
  lines.push(`String.join [ ${outs.join(', ')} ] "|"`);
  return program({ imports: ['import Maybe'], decls: RAND_DECLS, body: lines.join('\n') });
}


// ---- family 7: the cost of a frame -----------------------------------------------------------------------
//
// `size.chain.<op>.<n>.any`: one list written `n` times in a row, each write on what the last one answered.
// `size.dag.<k>.any`: a type whose two halves are one type, `2^(k-1)` levels deep. Both print what the
// plain build prints; the runner's 120 s limit makes a build that does not end a `CRASH -1`.
const CHAIN_OPS = {
  push: (p, i) => `List.push ${p} ${i}`,
  set: (p, i) => `List.set ${p} 0 ${i}`,
  spread: (p, i) => `[ …${p}, ${i} ]`,
  callee: (p) => `bumpL ${p}`,
  append: (p, i) => `${p} ++ [ ${i} ]`,
  join: (p, i, q) => `if n > ${i} then List.push ${p} ${i} else ${q}`,
};
function chainProgram(op, count) {
  const lines = ['v0 = [ n ]', 'v1 = [ n ]'];
  for (let i = 2; i <= count; i++) lines.push(`v${i} = ${CHAIN_OPS[op](`v${i - 1}`, i, `v${i - 2}`)}`);
  lines.push(`String.fromInt (List.length v${count})`);
  return program({ decls: [fn('bumpL', 'List Int → List Int', 'l', 'List.push l 7')], body: lines.join('\n') });
}
function dagProgram(depth) {
  const ws = ['w1 x = ( x, x )\n'];
  for (let i = 2; i <= depth; i++) ws.push(`w${i} x = w${i - 1} (w${i - 1} x)\n`);
  return { 'Main.beni': ['import Node exposing (Program)\n', ...ws, 'main : Program\nmain = Node.print "F"\n'].join('\n\n') };
}

// ---- write -----------------------------------------------------------------------------------------------
fs.mkdirSync(out, { recursive: true });
const list = [];
function emit(name, files) {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(files)) fs.writeFileSync(path.join(d, f), text);
  list.push(path.resolve(d));
}
for (const h of Object.keys(HOLDERS)) for (const w of Object.keys(WRITERS)) for (const side of ['x', 'h']) for (const twin of ['live', 'dead']) {
  emit(`hold.${h}.${w}${side === 'h' ? 'H' : ''}.${twin}`, holdProgram(h, w, side, twin));
}
for (const how of Object.keys(CELL_IN)) for (const edit of Object.keys(CELL_EDIT)) for (const twin of ['live', 'dead']) {
  emit(`cell.${how}.${edit}.${twin}`, cellProgram(how, edit, twin));
}
for (const s of Object.keys(CB_SHAPES)) for (const r of Object.keys(CB_RUNNERS)) for (const a of Object.keys(CB_ACTS)) for (const twin of ['live', 'dead']) {
  emit(`cb.${s}.${r}.${a}.${twin}`, cbProgram(s, r, a, twin));
}
for (const mk of Object.keys(DUP_MAKERS)) for (const w of Object.keys(DUP_WRITERS)) for (const twin of ['live', 'dead']) {
  emit(`dup.${mk}.${w}.${twin}`, dupProgram(mk, w, twin));
}
for (const mk of Object.keys(MOD_MAKERS)) for (const w of Object.keys(DUP_WRITERS)) for (const twin of ['live', 'dead']) {
  emit(`mod.${mk}.${w}.${twin}`, modProgram(mk, w, twin));
}
for (const op of Object.keys(CHAIN_OPS)) for (const count of [12, 20, 24, 40]) emit(`size.chain.${op}.${count}.any`, chainProgram(op, count));
for (const depth of [3, 4, 5, 6]) emit(`size.dag.${depth}.any`, dagProgram(depth));
const RANDS = Number(process.env.BLIND4B_RANDS ?? 4000);
const FROM = Number(process.env.BLIND4B_FROM ?? 1);
for (let seed = FROM; seed < FROM + RANDS; seed++) emit(`rand.${seed}.any`, randProgram(seed));
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
