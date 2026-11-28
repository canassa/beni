// blind7f.mjs <outdir> [filter]: research report 126, a seventh blind test (reader F).
//
// Families (a program's name is `<family>.<case>.<twin>`, twin `live` or `dead`):
//
// - `chain`: seeded, typed random chains. A list `inner` is put in a value of a random shape (a list of
//   lists, a pair, a record, a `Maybe`, a tree, a record read through a row), and the value goes through
//   two to four helpers drawn from a library: generic (`a → a`, `a × b → b × a`), over a row
//   (`{ r | items : a } → a`), over a tree (`Tree a → a`), concrete, through a `Ref`, a `Dict`, a fold, a
//   function value, a second module. A list is then dug out of the answer and written in place; `live`
//   reads `inner` after the write, `dead` does not. Seeds: `BLIND7F_CHAINS` (default 400) from
//   `BLIND7F_FROM` (default 1).
// - `tree`: a type argument that holds lists of the type itself (`Tree T`, `T` holds `List (Tree T)`)
//   read through generic and concrete helpers, with the write on a list that the deep level shares.
// - `dflt`: a function that hands a list to its function parameter and then writes it (directly, by a
//   method call, by a later binding, by a callee) or answers it; run directly, from a `Ref`, from a record
//   field, chosen by `if`, out of `Maybe.withDefault`, `List.head` or a `Dict`, or as a partial
//   application. The parameter keeps the list (`live`) or a copy (`dead`).
// - `entry`: The Elm Architecture on `browser-tea`, the model as a record, a record written through a
//   row-typed helper, a triple, a triple written through a generic helper; holders that keep a model list
//   (another field, a command that sleeps, a `Ref`, a message, a subscription, `init`).
// - `blowup`: a DAG of closures, each capturing three of the level below (`BLIND7F_LEVELS`, default 12):
//   the fault of report 126 §3, a compile whose time triples with each level.
//
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind7f.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const list = [];
function emit(name, files, extra = {}) {
  if (!name.includes(filter)) return;
  const dir = path.join(out, name);
  fs.mkdirSync(dir, { recursive: true });
  for (const [f, src] of Object.entries(files)) fs.writeFileSync(path.join(dir, f), src);
  if (extra.platform) fs.writeFileSync(path.join(dir, 'PLATFORM'), extra.platform + '\n');
  if (extra.steps) fs.writeFileSync(path.join(dir, 'steps'), extra.steps);
  list.push(path.resolve(dir));
}

// ---- a seeded random source -------------------------------------------------------------------
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}
const pick = (r, xs) => xs[Math.floor(r() * xs.length)];

// ---- the chain family ---------------------------------------------------------------------------
// Types: L (List Int), LL t, P a b, R t ({ items : t, other : List Int }), M t, Tr t.
const T = {
  L: () => ({ k: 'L' }), LL: (t) => ({ k: 'LL', t }), P: (a, b) => ({ k: 'P', a, b }),
  R: (t) => ({ k: 'R', t }), M: (t) => ({ k: 'M', t }), Tr: (t) => ({ k: 'Tr', t }),
};
const par = (s) => (s.includes(' ') && !/^\[[^\[\]]*\]$/.test(s) && !/^\{[^{}]*\}$/.test(s) ? `(${s})` : s);
function ty(t) {
  switch (t.k) {
    case 'L': return 'List Int';
    case 'LL': return `List ${par(ty(t.t))}`;
    case 'P': return `${par(ty(t.a))} × ${par(ty(t.b))}`;
    case 'R': return `Rec ${par(ty(t.t))}`;
    case 'M': return `Maybe ${par(ty(t.t))}`;
    case 'Tr': return `Tree ${par(ty(t.t))}`;
  }
}
function def(t) {
  switch (t.k) {
    case 'L': return '[]';
    case 'LL': return '[]';
    case 'P': return `( ${def(t.a)}, ${def(t.b)} )`;
    case 'R': return `{ items = ${def(t.t)}, other = [ 0 ] }`;
    case 'M': return 'Nothing';
    case 'Tr': return `Node ${par(def(t.t))} []`;
  }
}
// A string of every list in a value of type t (`show` functions are generated per type, by name).
const showers = new Map();
function showName(t) {
  const key = ty(t);
  if (!showers.has(key)) {
    const name = `show${showers.size}`;
    showers.set(key, { name, t, body: null });
    let body;
    switch (t.k) {
      case 'L': body = 'String.join (List.map v String.fromInt) ","'; break;
      case 'LL': body = `"[" ++ String.join (List.map v ${showName(t.t)}) ";" ++ "]"`; break;
      case 'P': body = `"(" ++ ${showName(t.a)} v.0 ++ "/" ++ ${showName(t.b)} v.1 ++ ")"`; break;
      case 'R': body = `"{" ++ ${showName(t.t)} v.items ++ "/" ++ show0L v.other ++ "}"`; break;
      case 'M': body = `case v of\n    Just x →\n        "J" ++ ${showName(t.t)} x\n\n    Nothing →\n        "N"`; break;
      case 'Tr': body = `case v of\n    Node x kids →\n        "T" ++ ${showName(t.t)} x ++ "<" ++ String.join (List.map kids ${showName(t)}) "," ++ ">"`; break;
    }
    showers.get(key).body = body;
  }
  return showers.get(key).name;
}

// Helpers: each takes the value of type `t` and answers a value; `ok(t)` says whether it applies.
// `call(x)` is the expression; `res(t)` is the answer's type.
const HELPERS = {
  same: { ok: () => true, res: (t) => t, call: (x) => `same ${par(x)}` },
  sameL: { ok: () => true, res: (t) => t, call: (x) => `(λv → v) ${par(x)}` },
  apply: { ok: () => true, res: (t) => t, call: (x) => `apply (λv → v) ${par(x)}` },
  applyTop: { ok: () => true, res: (t) => t, call: (x) => `apply same ${par(x)}` },
  twiceRun: { ok: () => true, res: (t) => t, call: (x) => `runTwice same ${par(x)}` },
  fold: { ok: () => true, res: (t) => t, call: (x) => `List.foldl [ 1, 2 ] ${par(x)} λ_ acc → acc` },
  foldKeep: { ok: () => true, res: (t) => t, call: (x) => `foldKeep ${par(x)}` },
  viaRef: { ok: () => true, res: (t) => t, call: (x) => `viaRef ${par(x)}` },
  viaDict: { ok: () => true, res: (t) => T.M(t), call: (x) => `viaDict ${par(x)}` },
  viaMod: { ok: () => true, res: (t) => t, call: (x) => `Lib.pass ${par(x)}` },
  dup: { ok: () => true, res: (t) => T.P(t, t), call: (x) => `dup ${par(x)}` },
  wrap: { ok: () => true, res: (t) => T.LL(t), call: (x) => `[ ${x} ]` },
  wrap2: { ok: () => true, res: (t) => T.LL(t), call: (x) => `pair2 ${par(x)}` },
  just: { ok: () => true, res: (t) => T.M(t), call: (x) => `Just ${par(x)}` },
  mkR: { ok: () => true, res: (t) => T.R(t), call: (x) => `mkR ${par(x)}` },
  node: { ok: () => true, res: (t) => T.Tr(t), call: (x) => `Node ${par(x)} []` },
  nodeKid: { ok: () => true, res: (t) => T.Tr(t), call: (x, t) => `Node ${par(def(t))} [ Node ${par(x)} [] ]` },
  pairL: { ok: () => true, res: (t) => T.P(t, T.L()), call: (x) => `( ${x}, [ 5 ] )` },
  swap: { ok: (t) => t.k === 'P', res: (t) => T.P(t.b, t.a), call: (x) => `swap ${par(x)}` },
  fst: { ok: (t) => t.k === 'P', res: (t) => t.a, call: (x) => `${par(x)}.0` },
  snd: { ok: (t) => t.k === 'P', res: (t) => t.b, call: (x) => `${par(x)}.1` },
  items: { ok: (t) => t.k === 'R', res: (t) => t.t, call: (x) => `itemsOf ${par(x)}` },
  rowSame: { ok: (t) => t.k === 'R', res: (t) => t, call: (x) => `rowSame ${par(x)}` },
  rowSwap: { ok: (t) => t.k === 'R' && t.t.k === 'L', res: (t) => t, call: (x) => `rowSwap ${par(x)}` },
  label: { ok: (t) => t.k === 'Tr', res: (t) => t.t, call: (x) => `labelOf ${par(x)}` },
  kids: { ok: (t) => t.k === 'Tr', res: (t) => T.LL(t), call: (x) => `kidsOf ${par(x)}` },
  firstKid: { ok: (t) => t.k === 'Tr', res: (t) => t, call: (x) => `firstKid ${par(x)}` },
  head: { ok: (t) => t.k === 'LL', res: (t) => T.M(t.t), call: (x) => `List.head ${par(x)}` },
  last: { ok: (t) => t.k === 'LL', res: (t) => T.M(t.t), call: (x) => `List.last ${par(x)}` },
  rev: { ok: (t) => t.k === 'LL', res: (t) => t, call: (x) => `List.reverse ${par(x)}` },
  take: { ok: (t) => t.k === 'LL' || t.k === 'L', res: (t) => t, call: (x) => `List.take ${par(x)} 5` },
  drop0: { ok: (t) => t.k === 'LL' || t.k === 'L', res: (t) => t, call: (x) => `List.drop ${par(x)} 0` },
  filt: { ok: (t) => t.k === 'LL', res: (t) => t, call: (x) => `List.filter ${par(x)} λ_ → True` },
  mapId: { ok: (t) => t.k === 'LL', res: (t) => t, call: (x) => `List.map ${par(x)} λq → q` },
  concat: { ok: (t) => t.k === 'LL' && t.t.k === 'LL', res: (t) => t.t, call: (x) => `List.concat ${par(x)}` },
  withDef: { ok: (t) => t.k === 'M', res: (t) => t.t, call: (x, t) => `Maybe.withDefault ${par(x)} ${par(def(t.t))}` },
  mapJ: { ok: (t) => t.k === 'M', res: (t) => t, call: (x) => `Maybe.map ${par(x)} λq → q` },
  andThen: { ok: (t) => t.k === 'M', res: (t) => t, call: (x) => `Maybe.andThen ${par(x)} Just` },
};
// Dig a `List Int` out of a value of type t: an expression with `v` bound, and a `case` when needed.
function dig(t, x, r) {
  switch (t.k) {
    case 'L': return x;
    case 'P': return r() < 0.5 && containsL(t.a) ? dig(t.a, `${par(x)}.0`, r) : (containsL(t.b) ? dig(t.b, `${par(x)}.1`, r) : dig(t.a, `${par(x)}.0`, r));
    case 'R': return dig(t.t, `${par(x)}.items`, r);
    case 'M': return dig(t.t, `Maybe.withDefault ${par(x)} ${par(def(t.t))}`, r);
    case 'LL': return dig(t.t, `Maybe.withDefault (List.head ${par(x)}) ${par(def(t.t))}`, r);
    case 'Tr': return r() < 0.5 ? dig(t.t, `labelOf ${par(x)}`, r) : dig(t, `firstKid ${par(x)}`, r);
  }
}
const containsL = () => true;

const WRITES = [
  (l) => `List.push ${par(l)} 9`,
  (l) => `List.set ${par(l)} 0 9`,
  (l) => `List.update ${par(l)} 0 λq → q + 9`,
  (l) => `List.pop ${par(l)}`,
];

const LIBRARY = `
type Tree a
    = Node a (List (Tree a))


type alias Rec t =
    items : t
    other : List Int


show0L : List Int → String
show0L v = String.join (List.map v String.fromInt) ","


same : a → a
same v = v


apply : (a → b), a → b
apply g v = g v


runTwice : (a → a), a → a
runTwice g v = g (g v)


foldKeep : a → a
foldKeep v = List.foldl [ 1, 2, 3 ] v λ_ acc → acc


viaRef : a → a
viaRef v =
    r = Ref.make v
    Ref.get r


viaDict : a → Maybe a
viaDict v = Dict.get (Dict.singleton 1 v) 1


dup : a → a × a
dup v = ( v, v )


pair2 : a → List a
pair2 v = [ v, v ]


mkR : t → Rec t
mkR v = { items = v, other = [ 0 ] }


swap : a × b → b × a
swap p = ( p.1, p.0 )


itemsOf : { r | items : a } → a
itemsOf r = r.items


rowSame : { r | items : a } → { r | items : a }
rowSame r = r


rowSwap : { r | items : List Int, other : List Int } → { r | items : List Int, other : List Int }
rowSwap r = { r | items = r.other, other = r.items }


labelOf : Tree a → a
labelOf t =
    case t of
        Node x _ →
            x


kidsOf : Tree a → List (Tree a)
kidsOf t =
    case t of
        Node _ k →
            k


firstKid : Tree a → Tree a
firstKid t =
    case t of
        Node _ k →
            case k of
                [ c, …_ ] →
                    c

                _ →
                    t
`;
const LIB_MOD = `pub pass : a → a
pass v =
    ( x, _ ) = ( v, 0 )
    x
`;

function chainProgram(seed) {
  const r = rng(seed * 2654435761);
  showers.clear();
  const steps = 2 + Math.floor(r() * 3);
  let t = T.L();
  let x = 'inner';
  const lines = ['inner = [ n, 2 ]'];
  const used = [];
  for (let i = 0; i < steps; i++) {
    const cands = Object.entries(HELPERS).filter(([, h]) => h.ok(t));
    const [hn, h] = pick(r, cands);
    used.push(hn);
    const e = h.call(x, t);
    t = h.res(t);
    lines.push(`v${i} = ${e}`);
    x = `v${i}`;
  }
  const l = dig(t, x, r);
  const w = pick(r, WRITES)(l);
  lines.push(`w = ${w}`);
  const sw = showName(T.L());
  const sv = showName(t);
  return { used, lines, t, x, sw, sv };
}

function chainFiles(seed, mode) {
  const c = chainProgram(seed);
  const read = mode === 'live' ? ` ++ "|" ++ ${c.sw} inner ++ "|" ++ ${c.sv} ${c.x}` : '';
  const body = [...c.lines, `${c.sw} w${read}`].join('\n');
  const shows = [...showers.values()].map((s) => `${s.name} : ${ty(s.t)} → String\n${s.name} v =\n${ind(s.body, 4)}\n`);
  const main = [
    'import Dict\nimport Lib\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport Ref\nimport String\n',
    LIBRARY,
    ...shows,
    `go : Int → String\ngo n =\n${ind(body, 4)}\n`,
    'main : Program\nmain = Node.print (go 1)\n',
  ].join('\n\n');
  return { files: { 'Main.beni': main, 'Lib.beni': LIB_MOD }, used: c.used };
}

const nChains = Number(process.env.BLIND7F_CHAINS ?? 400);
const from = Number(process.env.BLIND7F_FROM ?? 1);
for (let s = from; s < from + nChains; s++) {
  for (const mode of ['live', 'dead']) {
    const { files } = chainFiles(s, mode);
    emit(`chain.s${s}.${mode}`, files);
  }
}

// ---- shared text ------------------------------------------------------------------------------
const NODE_HDR = 'import Dict\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport Ref\nimport String\n\n\n'
  + 'show : List Int → String\nshow l = String.join (List.map l String.fromInt) ","\n\n\n'
  + 'bump : List Int → List Int\nbump l = List.push l 9\n';
const nodeMain = (decls, body) => [NODE_HDR, decls, `go : Int → String\ngo n =\n${ind(body, 4)}\n`, 'main : Program\nmain = Node.print (go 1)\n'].join('\n\n');

// ---- the tree family: `Tree T`, `T` holds `List (Tree T)` --------------------------------------
const TREE_DECLS = `type Tree a
    = Node a (List (Tree a))


type T
    = T (List Int) (List (Tree T))


labelOf : Tree a → a
labelOf t =
    case t of
        Node x _ →
            x


kidsOf : Tree a → List (Tree a)
kidsOf t =
    case t of
        Node _ k →
            k


firstKid : Tree a → Tree a
firstKid t =
    case kidsOf t of
        [ c, …_ ] →
            c

        _ →
            t


relabel : Tree a, a → Tree a
relabel t x =
    case t of
        Node _ k →
            Node x k


graft : Tree a, Tree a → Tree a
graft t c =
    case t of
        Node x k →
            Node x (List.push k c)


sumT : Tree T → Int
sumT t =
    case t of
        Node (T xs more) kids →
            List.sum xs + List.sum (List.map more sumT) + List.sum (List.map kids sumT)


inner : Tree T → List Int
inner t =
    case labelOf t of
        T xs _ →
            xs`;
// Each: the tree, and the expression of the list that is written.
const TREES = {
  // The deep node is a kid and also inside the root's label.
  labelKid: ['deep = Node (T [ n, 5 ] []) []\nt = Node (T [ 1 ] [ deep ]) [ deep ]', 'inner (firstKid t)'],
  // The deep node is only inside the root's label; reached through a generic helper over `Tree a`.
  viaLabel: ['deep = Node (T [ n, 5 ] []) []\nt = Node (T [ 1 ] [ deep ]) []', 'case labelOf t of\n    T _ more →\n        case more of\n            [ d, …_ ] →\n                inner d\n\n            _ →\n                []'],
  // `relabel` puts one label at two levels.
  relabel: ['lab = T [ n, 5 ] []\nt = relabel (Node lab [ Node lab [] ]) lab', 'inner (firstKid t)'],
  // `graft` adds the tree under itself.
  graft: ['leaf = Node (T [ n, 5 ] []) []\nt = graft leaf leaf', 'inner (firstKid t)'],
  // The root's label holds the root's own kids list's node.
  shared: ['ks = [ Node (T [ n ] []) [] ]\nt = Node (T [ 4 ] ks) ks', 'inner (firstKid t)'],
};
for (const [k, [mk, lst]] of Object.entries(TREES)) {
  for (const wr of ['push', 'set']) {
    for (const mode of ['live', 'dead']) {
      const w = wr === 'push' ? `List.push l 7` : `List.set l 0 7`;
      const body = `${mk}\nl =\n${ind(lst, 4)}\nw = ${w}\n${mode === 'live' ? 'show w ++ "|" ++ String.fromInt (sumT t)' : 'show w'}`;
      emit(`tree.${k}.${wr}.${mode}`, { 'Main.beni': nodeMain(TREE_DECLS, body) });
    }
  }
}

// ---- the dflt family: a function that hands a list to its function parameter, then writes it ---
// The holder: how the function is run (`direct` is a control): lines, given the function parameter `k`.
const DFLT_HOLDERS = {
  direct: (k) => [`w = work (${k}) [ n, 2 ]`],
  ref: (k) => ["holder = Ref.make work", `w = (Ref.get holder) (${k}) [ n, 2 ]`],
  record: (k) => ["r = { f = work }", `w = r.f (${k}) [ n, 2 ]`],
  withDefault: (k) => [`w = (Maybe.withDefault (Just work) work) (${k}) [ n, 2 ]`],
  listOf: (k) => [`w = (Maybe.withDefault (List.head [ work ]) work) (${k}) [ n, 2 ]`],
  dictOf: (k) => [`w = (Maybe.withDefault (Dict.get (Dict.singleton 1 work) 1) work) (${k}) [ n, 2 ]`],
  partial: (k) => ["p = work _ [ n, 2 ]", `w = p (${k})`],
  joined: (k) => ["f = if n > 0 then work else work", `w = f (${k}) [ n, 2 ]`],
};
// The function: what it does after it handed the list.
const DFLT_WORK = {
  push: "g xs\n    bump xs",
  method: "g xs\n    xs.push 9",
  later: "g xs\n    ys = List.push xs 9\n    ys",
  callee: "g xs\n    twice xs",
  answer: "g xs\n    xs",
};
for (const [hk, h] of Object.entries(DFLT_HOLDERS)) {
  for (const [wk, wb] of Object.entries(DFLT_WORK)) {
    for (const mode of ["live", "dead"]) {
      const decls = `twice : List Int → List Int\ntwice l = bump (bump l)\n\n\nwork : (List Int → ⊤), List Int → List Int\nwork g xs =\n    ${wb}\n`;
      const keeper = mode === "live" ? "λl → Ref.set cell l" : "λl → Ref.set cell (List.copy l)";
      const last = wk === "answer" ? "show (bump w) ++ \"|\" ++ show (Ref.get cell)" : "show w ++ \"|\" ++ show (Ref.get cell)";
      const body = ["cell = Ref.make []", ...h(keeper), last].join("\n");
      emit(`dflt.${hk}.${wk}.${mode}`, { "Main.beni": nodeMain(decls, body) });
    }
  }
}

// ---- the entry family: The Elm Architecture on `browser-tea` --------------------------------------
// `model`: the type, `init`, a show of it, the write `update` makes on `Add`, and the holder of `Keep`.
const TEA_HDR = 'import Browser\nimport Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport Ref\nimport Sub exposing (Sub)\nimport Tea\nimport Time\n\n\n'
  + 'show : List Int → String\nshow l = String.join (List.map l String.fromInt) ","\n';
const MODELS = {
  rec: {
    ty: 'type alias Model =\n    items : List Int\n    other : List Int\n    seen : Int',
    init: '{ items = [ 1 ], other = [ 5 ], seen = 0 }',
    show: 'show m.items ++ "/" ++ show m.other ++ "/" ++ String.fromInt m.seen',
    add: '{ m | items = List.push m.items 3 }',
    items: 'm.items',
    setOther: (e) => `{ m | other = ${e} }`,
    seen: (e) => `{ m | seen = ${e} }`,
    updTy: 'Model',
  },
  row: {
    ty: 'type alias Model =\n    items : List Int\n    other : List Int\n    seen : Int',
    init: '{ items = [ 1 ], other = [ 5 ], seen = 0 }',
    show: 'show m.items ++ "/" ++ show m.other ++ "/" ++ String.fromInt m.seen',
    add: 'pushItems m',
    items: 'm.items',
    setOther: (e) => `{ m | other = ${e} }`,
    seen: (e) => `{ m | seen = ${e} }`,
    updTy: 'Model',
    extra: 'pushItems : { r | items : List Int } → { r | items : List Int }\npushItems r = { r | items = List.push r.items 3 }\n',
  },
  pair: {
    ty: 'type alias Model =\n    List Int × List Int × Int',
    init: '( [ 1 ], [ 5 ], 0 )',
    show: 'show m.0 ++ "/" ++ show m.1 ++ "/" ++ String.fromInt m.2',
    add: '( List.push m.0 3, m.1, m.2 )',
    items: 'm.0',
    setOther: (e) => `( m.0, ${e}, m.2 )`,
    seen: (e) => `( m.0, m.1, ${e} )`,
    updTy: 'Model',
  },
  generic: {
    ty: 'type alias Model =\n    List Int × List Int × Int',
    init: '( [ 1 ], [ 5 ], 0 )',
    show: 'show m.0 ++ "/" ++ show m.1 ++ "/" ++ String.fromInt m.2',
    add: 'onFirst (λl → List.push l 3) m',
    items: 'm.0',
    setOther: (e) => `( m.0, ${e}, m.2 )`,
    seen: (e) => `( m.0, m.1, ${e} )`,
    updTy: 'Model',
    extra: 'onFirst : (a → a), a × b × c → a × b × c\nonFirst f t = ( f t.0, t.1, t.2 )\n',
  },
};
// Holders: `upd` is the `Keep` arm of `update` (the command too), `view` extra markup, `subs`, `init` override.
const HOLDERS = {
  copyOther: { upd: (M) => `( ${M.setOther(M.items)}, Cmd.none )` },
  cmdLater: { upd: (M) => `( m, Cmd.perform λsend →\n    Time.sleep (Time.millis 5)\n    send (Saw (List.sum ${M.items})) )` },
  refKeep: { upd: (M) => `( m, Cmd.perform λsend →\n    Ref.set cell ${M.items}\n    send (Saw 0) )`, view: '<p id="cell">{show (Ref.get cell)}</p>' },
  message: { upd: (M) => `( m, Cmd.none )`, view: (M) => `<button id="keep2" onClick={Got ${M.items}}>got</button>`, got: (M) => `( ${M.setOther('l')}, Cmd.none )` },
  sub: { upd: (M) => `( m, Cmd.none )`, subs: (M) => `Time.every (Time.millis 7) λ_ → Saw (List.length ${M.items})` },
  initTwice: { upd: (M) => `( m, Cmd.none )`, init: { rec: 'xs = [ 1 ]\n( { items = xs, other = xs, seen = 0 }, Cmd.none )', row: 'xs = [ 1 ]\n( { items = xs, other = xs, seen = 0 }, Cmd.none )', pair: 'xs = [ 1 ]\n( ( xs, xs, 0 ), Cmd.none )', generic: 'xs = [ 1 ]\n( ( xs, xs, 0 ), Cmd.none )' } },
  none: { upd: (M) => `( m, Cmd.none )` },
};
for (const [mk, M] of Object.entries(MODELS)) {
  for (const [hk, H] of Object.entries(HOLDERS)) {
    for (const mode of ['live', 'dead']) {
      // The dead twin's holder takes a copy.
      const MM = mode === 'dead' ? { ...M, items: '[ 7 ]' } : M;
      const keepArm = H.upd(MM);
      const gotArm = H.got ? H.got(MM) : '( m, Cmd.none )';
      const viewExtra = typeof H.view === 'function' ? H.view(MM) : (H.view ?? '');
      const subs = H.subs ? `λm → ${H.subs(MM)}` : 'λ_ → Sub.none';
      const init = H.init ? (mode === 'dead' ? H.init[mk].replace('xs, ', '(List.copy xs), ').replace('= xs, other', '= (List.copy xs), other') : H.init[mk]) : `( ${M.init}, Cmd.none )`;
      const src = [
        TEA_HDR,
        M.ty + '\n',
        'type Msg\n    = Add\n    | Keep\n    | Saw Int\n    | Got (List Int)\n',
        M.extra ?? '',
        'cell : Ref.Ref (List Int)\ncell = Ref.make []\n',
        `update : Msg, Model → Model × Cmd Msg\nupdate msg m =\n    case msg of\n        Add →\n            ( ${M.add}, Cmd.none )\n\n        Keep →\n${ind(keepArm, 12)}\n\n        Saw k →\n            ( ${M.seen('k')}, Cmd.none )\n\n        Got l →\n            ${gotArm}\n`,
        `view : Model → Html Msg\nview m =\n    <main>\n        <p id="m">{${M.show}}</p>\n        <button id="add" onClick={Add}>add</button>\n        <button id="keep" onClick={Keep}>keep</button>\n${viewExtra ? ind(viewExtra, 8) + '\n' : ''}    </main>\n`,
        `main : Browser.Program\nmain =\n    Tea.element\n        { init =\n            λ⊤ →\n${ind(init, 16)}\n        , update = update\n        , view = view\n        , subscriptions = ${subs}\n        }\n`,
      ].filter(Boolean).join('\n\n');
      const steps = hk === 'message' ? 'click #keep2\nclick #add\nclick #add\nadvance 20\n' : 'click #keep\nclick #add\nadvance 20\nclick #add\nadvance 20\n';
      emit(`entry.${mk}.${hk}.${mode}`, { 'Main.beni': src }, { platform: 'platforms/browser-tea', steps });
    }
  }
}

// ---- the blowup family: a DAG of closures, each capturing the two of the level below -------------
// The checker walks each path of the DAG (`flow`, `flowCaptures`), so the work doubles with each level
// (triples with three per level); the plain build is linear. `BLIND7F_LEVELS` (default 12) sets the depth.
const levels = Number(process.env.BLIND7F_LEVELS ?? 12);
for (const holder of ['call', 'ref']) {
  for (const mode of ['live', 'dead']) {
    const lines = ['a0 = λl → List.take l n', 'b0 = λl → List.reverse l', 'c0 = λl → List.drop l 1'];
    for (let i = 1; i <= levels; i++) {
      const p = i - 1;
      lines.push(`a${i} = λl → a${p} (b${p} (c${p} l))`, `b${i} = λl → b${p} (c${p} (a${p} l))`, `c${i} = λl → c${p} (a${p} (b${p} l))`);
    }
    const f = holder === 'ref' ? `(Ref.get (Ref.make a${levels}))` : `a${levels}`;
    lines.push('xs = [ n, 2 ]', 'ys = List.push xs 3', `show ys ++ show (${f} [ 4, 5 ])${mode === 'live' ? ' ++ show xs' : ''}`);
    emit(`blowup.${holder}.l${levels}.${mode}`, { 'Main.beni': nodeMain('', lines.join('\n')) });
  }
}

fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs in ${out}`);
